// Mascot for familiar: a transparent always-on-top character, a speech bubble that follows it,
// and a large speech bubble with the suggestions. It only reads live.json; every state change goes through the familiar CLI.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
use std::{fs, os::fd::AsRawFd, path::{Path, PathBuf}, process::Command};
use tauri::{ipc::Response, AppHandle, Emitter, LogicalSize, Manager, PhysicalPosition, PhysicalSize, WebviewWindow, WindowEvent};

const BUBBLE_OVERLAP: f64 = 110.0; // logical px the bubble overlaps the mascot window, so the tail reaches her
const BUBBLE_GAP: f64 = 12.0; // logical px between the bubble and the bottom screen edge
const PANEL_WIDTH: f64 = 500.0;

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
fn quit(app: AppHandle) { app.exit(0); }

#[tauri::command]
fn log(msg: String) { eprintln!("[page] {msg}"); }

#[tauri::command]
fn qa_flags() -> String { std::env::var("MASCOT_QA").unwrap_or_default() }

fn packs_dir() -> PathBuf { home().join(".local/share/familiar/packs") }

fn is_pack_id(id: &str) -> bool {
    !id.is_empty() && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// The character chosen in config.json. None means the default pack in the app.
#[tauri::command]
fn character() -> Option<String> {
    let config = fs::read(state_dir().join("config.json")).ok()?;
    let value: serde_json::Value = serde_json::from_slice(&config).ok()?;
    let id = value.get("character")?.as_str()?;
    (is_pack_id(id) && packs_dir().join(id).is_dir()).then(|| id.to_string())
}

#[tauri::command]
fn pack_file(id: String, name: String) -> Result<Response, String> {
    let safe = is_pack_id(&id) && (name == "clips.json"
        || name.strip_suffix(".mp4").is_some_and(is_pack_id));
    if !safe { return Err("invalid pack file".into()); }
    fs::read(packs_dir().join(id).join("clips").join(name)).map(Response::new).map_err(|e| e.to_string())
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
    let left = pos.x - size.width as i32 + (BUBBLE_OVERLAP * scale) as i32;
    // Stay on the bottom screen edge even when the mascot is dragged upward.
    let Some(mon) = main.current_monitor()?.or(main.primary_monitor()?) else { return Ok(()) };
    let bottom = mon.position().y + mon.size().height as i32;
    bubble.set_position(PhysicalPosition::new(left, bottom - size.height as i32 - (BUBBLE_GAP * scale) as i32))
}

#[tauri::command]
fn bubble(app: AppHandle, text: String) -> Result<(), String> {
    let (main, win) = (app.get_webview_window("main").unwrap(), app.get_webview_window("bubble").unwrap());
    if text.is_empty() { return win.hide().map_err(|e| e.to_string()); }
    place_bubble(&main, &win).map_err(|e| e.to_string())?;
    win.emit("bubble-text", text).map_err(|e| e.to_string())?;
    win.show().map_err(|e| e.to_string())
}

#[tauri::command]
fn show_panel(app: AppHandle) -> Result<(), String> {
    let (main, win) = (app.get_webview_window("main").unwrap(), app.get_webview_window("panel").unwrap());
    place_bubble(&main, &win).map_err(|e| e.to_string())?;
    win.emit("panel-open", ()).map_err(|e| e.to_string())
}

/// The panel asks for its height once its content is laid out, then appears at that size.
#[tauri::command]
fn fit_panel(app: AppHandle, height: f64) -> Result<(), String> {
    let (main, win) = (app.get_webview_window("main").unwrap(), app.get_webview_window("panel").unwrap());
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
        .invoke_handler(tauri::generate_handler![quit, log, qa_flags, character, pack_file, live, familiar, open_url, bubble, show_panel, fit_panel, hide_panel])
        .setup(|app| {
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
            win.show()?;

            let bubble = app.get_webview_window("bubble").unwrap();
            bubble.set_ignore_cursor_events(true)?;
            let panel = app.get_webview_window("panel").unwrap();
            let main = win.clone();
            win.on_window_event(move |e| {
                if let WindowEvent::Moved(_) = e {
                    let _ = place_bubble(&main, &bubble);
                    let _ = place_bubble(&main, &panel);
                }
            });
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
