// Mascot for familiar: a transparent always-on-top character, a speech bubble that follows it,
// and a large speech bubble with the suggestions. It only reads live.json; every state change goes through the familiar CLI.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
use std::{fs, os::fd::AsRawFd, path::{Path, PathBuf}, process::Command, sync::Mutex};
use serde_json::{json, Map, Value};
use tauri::{
    ipc::Response,
    menu::{Menu, MenuItem, PredefinedMenuItem},
    AppHandle, Emitter, LogicalPosition, LogicalSize, Manager, PhysicalPosition, PhysicalSize, State, WebviewWindow, WindowEvent,
};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};

const BUBBLE_OVERLAP: f64 = 73.0; // logical px the bubble overlaps the mascot window, so the tail reaches her
const BUBBLE_GAP: f64 = 12.0; // logical px between the bubble and the bottom screen edge
const PANEL_WIDTH: f64 = 500.0;
const DEFAULT_HOTKEY: &str = "Control+Alt+Space";
const NOTCH_WING: f64 = 52.0; // logical px shown on each side of the notch
const NOTCH_LEVEL: isize = 27; // above the menu bar (24) and status items (25)

fn home() -> PathBuf { PathBuf::from(std::env::var("HOME").unwrap_or_default()) }

fn state_dir() -> PathBuf {
    std::env::var("FAMILIAR_STATE").map(PathBuf::from)
        .unwrap_or_else(|_| home().join(".local/state/familiar"))
}

fn exe() -> PathBuf { std::env::current_exe().unwrap_or_default() }

fn familiar_bin() -> PathBuf {
    if let Ok(path) = std::env::var("FAMILIAR_BIN") { return path.into(); }
    let bundled = exe().with_file_name("familiar");
    if bundled.exists() { bundled } else { home().join(".local/bin/familiar") }
}

fn plist(label: &str, program: &[&str], extra: &str) -> String {
    let args: String = program.iter().map(|a| format!("<string>{a}</string>")).collect();
    format!(r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{label}</string>
  <key>ProgramArguments</key><array>{args}</array>
  {extra}
</dict>
</plist>
"#)
}

/// Writes a LaunchAgent. Returns true when the file changed.
fn write_agent(dir: &Path, label: &str, body: String) -> std::io::Result<bool> {
    let path = dir.join(format!("{label}.plist"));
    if fs::read_to_string(&path).is_ok_and(|old| old == body) { return Ok(false); }
    fs::write(path, body)?;
    Ok(true)
}

/// Moves an install from the old desk-steward name. Old agents would keep scanning alongside the
/// new ones, and suggestions and cursors must survive, so this runs before anything touches the state.
fn migrate_legacy() {
    if !exe().starts_with("/Applications") { return; }
    let (dir, domain) = (home().join("Library/LaunchAgents"), format!("gui/{}", unsafe { libc::getuid() }));
    for label in ["dev.qluto.desk-steward.tick", "dev.qluto.desk-steward.mascot"] {
        let path = dir.join(format!("{label}.plist"));
        if path.exists() {
            let _ = Command::new("launchctl").args(["bootout", &format!("{domain}/{label}")]).status();
            let _ = fs::remove_file(path);
        }
    }
    let old = home().join(".local/state/desk-steward");
    if old.exists() && !state_dir().exists() {
        if let Err(e) = fs::rename(&old, state_dir()) { eprintln!("failed to migrate state: {e}"); }
    }
}

/// Registers scanning and login start for the installed app, so a dmg install needs no scripts.
/// Skipped for dev builds and for an app still running from the dmg, whose paths would not last.
fn register_agents() -> std::io::Result<()> {
    let (exe, familiar) = (exe(), familiar_bin());
    if !exe.starts_with("/Applications") { return Ok(()); }
    let dir = home().join("Library/LaunchAgents");
    let log = state_dir().join("tick.out.log");
    fs::create_dir_all(&dir)?;
    fs::create_dir_all(state_dir())?;
    let domain = format!("gui/{}", unsafe { libc::getuid() });

    // Waking every 5 minutes is cheap: `tick` itself decides whether to scan.
    let label = "io.qluto.familiar.tick";
    let tick = plist(label, &[&familiar.to_string_lossy(), "tick"], &format!(
        r#"<key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>{0}</string>
  <key>StandardErrorPath</key><string>{0}</string>"#, log.display()));
    if write_agent(&dir, label, tick)? {
        let plist = dir.join(format!("{label}.plist"));
        let _ = Command::new("launchctl").args(["bootout", &format!("{domain}/{label}")]).status();
        Command::new("launchctl").arg("bootstrap").arg(domain).arg(plist).status()?;
    }

    // Loaded at the next login. This process is already the running mascot, so it is not bootstrapped now.
    // A right-click quit exits cleanly and stays closed.
    write_agent(&dir, "io.qluto.familiar.mascot", plist("io.qluto.familiar.mascot", &[&exe.to_string_lossy()],
        &format!(r#"<key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>{}</string>"#, state_dir().join("mascot.log").display())))?;
    Ok(())
}

/// Login start and Launchpad can both launch the app. Only the first one stays; the lock lasts as long as the process.
fn acquire_single_instance() -> Option<fs::File> {
    fs::create_dir_all(state_dir()).ok()?;
    let lock = fs::File::create(state_dir().join("mascot.lock")).ok()?;
    (unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0).then_some(lock)
}

#[tauri::command]
fn log(msg: String) { eprintln!("[page] {msg}"); }

#[tauri::command]
fn qa_flags() -> String { std::env::var("MASCOT_QA").unwrap_or_default() }

fn config_path() -> PathBuf { state_dir().join("config.json") }

/// A missing file is an empty config. A broken one is an error, so saving never wipes it.
fn read_config() -> Result<Map<String, Value>, String> {
    match fs::read(config_path()) {
        Ok(bytes) => serde_json::from_slice(&bytes).map_err(|e| format!("config.json を読めません: {e}")),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Map::new()),
        Err(e) => Err(e.to_string()),
    }
}

/// Keeps every other key: the CLI reads this file too.
fn save_config(key: &str, value: Value) -> Result<(), String> {
    let mut config = read_config()?;
    config.insert(key.into(), value);
    let bytes = serde_json::to_vec_pretty(&config).map_err(|e| e.to_string())?;
    fs::create_dir_all(state_dir()).map_err(|e| e.to_string())?;
    let tmp = config_path().with_extension("json.tmp");
    fs::write(&tmp, bytes).and_then(|_| fs::rename(&tmp, config_path())).map_err(|e| e.to_string())
}

/// `active` is false when the shortcut could not be registered. The page then stays clickable,
/// because the hotkey would otherwise be the only way to reach the mascot.
struct Hotkey { keys: String, active: bool }

fn parse_hotkey(keys: &str) -> Result<Shortcut, String> {
    let shortcut: Shortcut = keys.parse().map_err(|_| "このキーは使えません".to_string())?;
    if !shortcut.mods.intersects(Modifiers::CONTROL | Modifiers::ALT | Modifiers::SUPER) {
        return Err("⌃ ⌥ ⌘ のどれかと組み合わせてください".into());
    }
    Ok(shortcut)
}

fn register_hotkey(app: &AppHandle, keys: &str) -> Result<(), String> {
    app.global_shortcut().register(parse_hotkey(keys)?).map_err(|_| "このキーは他で使われています".to_string())
}

fn hotkey_json(hotkey: &Hotkey) -> Value { json!({ "keys": hotkey.keys, "active": hotkey.active }) }

#[tauri::command]
fn hotkey(state: State<Mutex<Hotkey>>) -> Value { hotkey_json(&state.lock().unwrap()) }

/// True once, so the hint about the hotkey appears on the first launch only.
#[tauri::command]
fn first_run() -> bool {
    let seen = read_config().map_or(true, |c| c.contains_key("hotkeyHintShown"));
    !seen && save_config("hotkeyHintShown", json!(true)).is_ok()
}

/// A combination being typed into settings must not also summon the mascot.
#[tauri::command]
fn hotkey_recording(app: AppHandle, state: State<Mutex<Hotkey>>, on: bool) -> Result<(), String> {
    if on { return app.global_shortcut().unregister_all().map_err(|e| e.to_string()); }
    let mut hotkey = state.lock().unwrap();
    hotkey.active = register_hotkey(&app, &hotkey.keys).is_ok();
    app.emit("hotkey-changed", hotkey_json(&hotkey)).map_err(|e| e.to_string())
}

#[tauri::command]
fn set_hotkey(app: AppHandle, state: State<Mutex<Hotkey>>, keys: String) -> Result<Value, String> {
    let mut hotkey = state.lock().unwrap();
    let _ = app.global_shortcut().unregister_all();
    let saved = register_hotkey(&app, &keys).and_then(|_| save_config("hotkey", json!(keys)));
    if let Err(e) = saved {
        let _ = app.global_shortcut().unregister_all();
        hotkey.active = register_hotkey(&app, &hotkey.keys).is_ok();
        app.emit("hotkey-changed", hotkey_json(&hotkey)).map_err(|e| e.to_string())?;
        return Err(e);
    }
    *hotkey = Hotkey { keys, active: true };
    let value = hotkey_json(&hotkey);
    app.emit("hotkey-changed", &value).map_err(|e| e.to_string())?;
    Ok(value)
}

#[tauri::command]
fn context_menu(app: AppHandle, window: WebviewWindow) -> Result<(), String> {
    let build = || -> tauri::Result<()> {
        let settings = MenuItem::with_id(&app, "settings", "設定…", true, None::<&str>)?;
        let quit = MenuItem::with_id(&app, "quit", "familiar を終了", true, None::<&str>)?;
        window.popup_menu(&Menu::with_items(&app, &[&settings, &PredefinedMenuItem::separator(&app)?, &quit])?)
    };
    build().map_err(|e| e.to_string())
}

/// The notch in top-left logical coordinates.
#[derive(Clone, Copy)]
struct NotchRect { x: f64, y: f64, width: f64, height: f64 }

fn notch_rect() -> Option<NotchRect> {
    let mtm = objc2::MainThreadMarker::new()?;
    let screens = objc2_app_kit::NSScreen::screens(mtm);
    let primary_height = screens.iter().next()?.frame().size.height;
    screens.iter().find_map(|screen| {
        let height = screen.safeAreaInsets().top;
        if height <= 0.0 { return None; }
        let (frame, left, right) = (screen.frame(), screen.auxiliaryTopLeftArea(), screen.auxiliaryTopRightArea());
        let start = left.origin.x + left.size.width;
        Some(NotchRect {
            x: frame.origin.x + start,
            y: primary_height - frame.origin.y - frame.size.height,
            width: right.origin.x - start,
            height,
        })
    })
}

/// "notch" only when a screen has one, so a closed lid or a desktop falls back to the character.
fn display_mode() -> &'static str {
    let wanted = read_config().ok().and_then(|c| c.get("display")?.as_str().map(|m| m == "notch")).unwrap_or(false);
    if wanted && notch_rect().is_some() { "notch" } else { "character" }
}

#[tauri::command]
fn display() -> Value { json!({ "mode": display_mode(), "hasNotch": notch_rect().is_some() }) }

#[tauri::command]
fn set_display(app: AppHandle, mode: String) -> Result<Value, String> {
    if mode != "character" && mode != "notch" { return Err("invalid display".into()); }
    save_config("display", json!(mode))?;
    let (main, notch) = (app.get_webview_window("main").unwrap(), app.get_webview_window("notch").unwrap());
    let result = if display_mode() == "notch" { main.hide() } else { notch.hide().and_then(|_| main.show()) };
    result.map_err(|e| e.to_string())?;
    let value = display();
    app.emit("display-changed", &value).map_err(|e| e.to_string())?;
    Ok(value)
}

/// Shows the wings around the notch. An empty state hides the window, so the menu bar stays usable.
#[tauri::command]
fn notch(app: AppHandle, state: Value) -> Result<(), String> {
    let win = app.get_webview_window("notch").unwrap();
    let shown = state.as_object().is_some_and(|s| !s.is_empty());
    let (true, Some(rect)) = (shown, notch_rect()) else { return win.hide().map_err(|e| e.to_string()) };
    let apply = || -> tauri::Result<()> {
        win.set_size(LogicalSize::new(rect.width + NOTCH_WING * 2.0, rect.height))?;
        win.set_position(LogicalPosition::new(rect.x - NOTCH_WING, rect.y))?;
        win.emit("notch-state", &state)?;
        win.show()
    };
    apply().map_err(|e| e.to_string())
}

/// Joins every Space. macOS keeps a window out of full-screen Spaces unless it is marked as auxiliary.
fn float(win: &WebviewWindow, level: Option<isize>, over_full_screen: bool) -> tauri::Result<()> {
    use objc2_app_kit::{NSWindow, NSWindowCollectionBehavior as Behavior};
    let window = win.ns_window()? as *const NSWindow;
    let window = unsafe { &*window };
    if let Some(level) = level { window.setLevel(level); }
    let spaces = Behavior::CanJoinAllSpaces | Behavior::Stationary | Behavior::IgnoresCycle;
    window.setCollectionBehavior(if over_full_screen { spaces | Behavior::FullScreenAuxiliary } else { spaces });
    Ok(())
}

#[tauri::command]
fn show_settings(app: AppHandle) -> Result<(), String> { open_settings(&app).map_err(|e| e.to_string()) }

fn open_settings(app: &AppHandle) -> tauri::Result<()> {
    let panel = app.get_webview_window("panel").unwrap();
    if panel.is_visible()? { // the settings bubble takes the same spot
        panel.hide()?;
        app.emit("panel-closed", ())?;
    }
    app.emit("settings-open", ())
}

#[tauri::command]
fn hide_settings(app: AppHandle) -> Result<(), String> {
    app.get_webview_window("settings").unwrap().hide().map_err(|e| e.to_string())?;
    app.emit("settings-closed", ()).map_err(|e| e.to_string())
}

fn packs_dir() -> PathBuf { home().join(".local/share/familiar/packs") }

fn is_pack_id(id: &str) -> bool {
    !id.is_empty() && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// The character chosen in config.json. None means the default pack in the app.
#[tauri::command]
fn character() -> Option<String> {
    let config = read_config().ok()?;
    let id = config.get("character")?.as_str()?;
    (is_pack_id(id) && packs_dir().join(id).is_dir()).then(|| id.to_string())
}

#[tauri::command]
fn pack_file(id: String, name: String) -> Result<Response, String> {
    let safe = is_pack_id(&id) && (name == "clips.json"
        || name.strip_suffix(".mp4").is_some_and(is_pack_id));
    if !safe { return Err("invalid pack file".into()); }
    fs::read(packs_dir().join(id).join("clips").join(name)).map(Response::new).map_err(|e| e.to_string())
}

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGEventSourceSecondsSinceLastEventType(state: i32, event_type: u32) -> f64;
}

/// Seconds since the last keyboard or mouse input. Needs no permission and reads no input.
#[tauri::command]
fn idle_seconds() -> f64 {
    const COMBINED_SESSION_STATE: i32 = 0;
    const ANY_INPUT_EVENT: u32 = u32::MAX;
    unsafe { CGEventSourceSecondsSinceLastEventType(COMBINED_SESSION_STATE, ANY_INPUT_EVENT) }
}

#[tauri::command]
fn live() -> String {
    std::fs::read_to_string(state_dir().join("live.json")).unwrap_or_else(|_| "{}".into())
}

/// Runs the familiar CLI. Accepting takes seconds, so this stays off the main thread.
#[tauri::command]
async fn familiar(args: Vec<String>) -> Result<String, String> {
    const ALLOWED: [&str; 4] = ["list", "accept", "dismiss", "snooze"];
    if !args.first().is_some_and(|c| ALLOWED.contains(&c.as_str())) {
        return Err("command not allowed".into());
    }
    tauri::async_runtime::spawn_blocking(move || {
        let out = Command::new(familiar_bin()).args(&args).output().map_err(|e| e.to_string())?;
        if out.status.success() {
            Ok(String::from_utf8_lossy(&out.stdout).into_owned())
        } else {
            Err(String::from_utf8_lossy(&out.stderr).into_owned())
        }
    }).await.map_err(|e| e.to_string())?
}

/// Only web links leave the app. Suggestion URLs come from untrusted mail and pages.
#[tauri::command]
fn open_url(url: String) -> Result<(), String> {
    if !url.starts_with("https://") { return Err("https only".into()); }
    Command::new("open").arg(url).status().map(|_| ()).map_err(|e| e.to_string())
}

fn place_bubble(main: &WebviewWindow, bubble: &WebviewWindow) -> tauri::Result<()> {
    place(main, bubble, bubble.outer_size()?)
}

/// `size` is passed in because outer_size() still reports the old size right after set_size().
fn place(main: &WebviewWindow, bubble: &WebviewWindow, size: PhysicalSize<u32>) -> tauri::Result<()> {
    let (pos, scale) = (main.outer_position()?, main.scale_factor()?);
    if let (true, Some(rect)) = (bubble.label() != "bubble" && display_mode() == "notch", notch_rect()) {
        let left = rect.x + (rect.width - size.width as f64 / scale) / 2.0;
        return bubble.set_position(LogicalPosition::new(left, rect.y + rect.height + 6.0));
    }
    let left = pos.x - size.width as i32 + (BUBBLE_OVERLAP * scale) as i32;
    // Stay on the bottom screen edge even when the mascot is dragged upward.
    let Some(mon) = main.current_monitor()?.or(main.primary_monitor()?) else { return Ok(()) };
    let bottom = mon.position().y + mon.size().height as i32;
    bubble.set_position(PhysicalPosition::new(left, bottom - size.height as i32 - (BUBBLE_GAP * scale) as i32))
}

#[tauri::command]
fn bubble(app: AppHandle, text: String) -> Result<(), String> {
    let (main, win) = (app.get_webview_window("main").unwrap(), app.get_webview_window("bubble").unwrap());
    win.emit("bubble-text", &text).map_err(|e| e.to_string())?;
    if text.is_empty() { return win.hide().map_err(|e| e.to_string()); }
    place_bubble(&main, &win).map_err(|e| e.to_string())?;
    win.show().map_err(|e| e.to_string())
}

#[tauri::command]
fn show_panel(app: AppHandle) -> Result<(), String> {
    let (main, win) = (app.get_webview_window("main").unwrap(), app.get_webview_window("panel").unwrap());
    place_bubble(&main, &win).map_err(|e| e.to_string())?;
    win.emit("panel-open", ()).map_err(|e| e.to_string())
}

/// A large bubble (suggestions or settings) asks for its height once its content is laid out, then appears at that size.
#[tauri::command]
fn fit_panel(app: AppHandle, window: WebviewWindow, height: f64) -> Result<(), String> {
    let (main, win) = (app.get_webview_window("main").unwrap(), window);
    let size = LogicalSize::new(PANEL_WIDTH, height);
    win.set_size(size).map_err(|e| e.to_string())?;
    place(&main, &win, size.to_physical(main.scale_factor().map_err(|e| e.to_string())?)).map_err(|e| e.to_string())?;
    win.show().map_err(|e| e.to_string())?;
    win.set_focus().map_err(|e| e.to_string())
}

#[tauri::command]
fn hide_panel(app: AppHandle) -> Result<(), String> {
    app.get_webview_window("panel").unwrap().hide().map_err(|e| e.to_string())?;
    app.emit("panel-closed", ()).map_err(|e| e.to_string())
}

fn main() {
    migrate_legacy();
    let Some(_instance) = acquire_single_instance() else { return };
    if let Err(e) = register_agents() { eprintln!("failed to register agents: {e}"); }
    tauri::Builder::default()
        .plugin(tauri_plugin_global_shortcut::Builder::new().with_handler(|app, _, event| {
            if event.state() == ShortcutState::Pressed { let _ = app.emit_to("main", "hotkey", ()); }
        }).build())
        .on_menu_event(|app, event| match event.id().as_ref() {
            "settings" => { let _ = open_settings(app); }
            "quit" => app.exit(0),
            _ => {}
        })
        .invoke_handler(tauri::generate_handler![log, qa_flags, character, pack_file, live, familiar, open_url, bubble, show_panel, fit_panel, hide_panel, hotkey, first_run, hotkey_recording, set_hotkey, context_menu, show_settings, hide_settings, idle_seconds, display, set_display, notch])
        .setup(|app| {
            let keys = read_config().ok().and_then(|c| c.get("hotkey")?.as_str().map(String::from))
                .unwrap_or_else(|| DEFAULT_HOTKEY.into());
            let active = register_hotkey(app.handle(), &keys).inspect_err(|e| eprintln!("hotkey {keys}: {e}")).is_ok();
            app.manage(Mutex::new(Hotkey { keys, active }));

            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            let win = app.get_webview_window("main").unwrap();
            if let (Ok(Some(mon)), Ok(size)) = (win.primary_monitor(), win.outer_size()) {
                let (area, pos) = (mon.size(), mon.position());
                let margin = (24.0 * mon.scale_factor()) as i32;
                win.set_position(PhysicalPosition::new(
                    pos.x + area.width as i32 - size.width as i32 - margin,
                    pos.y + area.height as i32 - size.height as i32,
                ))?;
            }
            win.set_ignore_cursor_events(true)?;
            if display_mode() != "notch" { win.show()?; }
            float(&app.get_webview_window("notch").unwrap(), Some(NOTCH_LEVEL), false)?;
            float(&app.get_webview_window("panel").unwrap(), None, true)?;
            float(&app.get_webview_window("settings").unwrap(), None, true)?;

            let bubble = app.get_webview_window("bubble").unwrap();
            bubble.set_ignore_cursor_events(true)?;
            let panel = app.get_webview_window("panel").unwrap();
            let settings = app.get_webview_window("settings").unwrap();
            let main = win.clone();
            win.on_window_event(move |e| {
                if let WindowEvent::Moved(_) = e {
                    let _ = place_bubble(&main, &bubble);
                    let _ = place_bubble(&main, &panel);
                    let _ = place_bubble(&main, &settings);
                }
            });
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hotkey_accepts_what_settings_records() {
        for keys in [DEFAULT_HOTKEY, "Control+Alt+KeyK", "Command+Shift+Digit1", "Alt+Comma", "Control+ArrowUp", "Control+Alt+F5"] {
            assert!(parse_hotkey(keys).is_ok(), "{keys}");
        }
    }

    #[test]
    fn hotkey_needs_a_real_modifier() {
        for keys in ["KeyA", "Shift+KeyA", "Control+", "Control+NotAKey"] {
            assert!(parse_hotkey(keys).is_err(), "{keys}");
        }
    }
}
