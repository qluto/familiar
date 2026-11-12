// Updates the installed app from GitHub Releases. The download and the install happen in the background;
// the restart waits for a quiet moment, so a conversation or a settings change is never cut off.
use std::{process::Command, sync::Mutex, thread, time::Duration};
use serde_json::json;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_updater::UpdaterExt;

const FIRST_CHECK: Duration = Duration::from_secs(60);
const CHECK_EVERY: Duration = Duration::from_secs(6 * 3600);
const RETRY_RESTART: Duration = Duration::from_secs(60);
/// No keyboard or mouse input for this long counts as away.
const IDLE_BEFORE_RESTART: f64 = 120.0;
/// The version already installed into the bundle and waiting for a restart.
static READY: Mutex<Option<String>> = Mutex::new(None);
/// Held while checking, so the periodic check and the menu do not download at the same time.
static CHECKING: Mutex<()> = Mutex::new(());
const BUSY: &str = "already checking";

/// Only the app in /Applications updates itself. A dev build or an app still running from the dmg would
/// replace the wrong copy.
pub fn start(app: AppHandle) {
    if !crate::exe().starts_with("/Applications") { return; }
    thread::spawn(move || {
        thread::sleep(FIRST_CHECK);
        loop {
            match check(&app) {
                Ok(true) => return restart_when_quiet(&app),
                Ok(false) if READY.lock().unwrap().is_some() => return, // the menu found it and waits to restart
                Ok(false) => {}
                Err(e) => eprintln!("update: {e}"),
            }
            thread::sleep(CHECK_EVERY);
        }
    });
}

/// The menu item: check right away and say what came of it.
pub fn check_now(app: AppHandle) {
    if !crate::exe().starts_with("/Applications") { return say(&app, "アップデートは /Applications のアプリだけが確かめます"); }
    if let Some(version) = READY.lock().unwrap().clone() { let _ = app.emit("update-ready", version); return; }
    say(&app, "新しい版がないか確かめています");
    thread::spawn(move || match check(&app) {
        // 見つかったときは update-ready が知らせる。再起動は定期の確認と同じく、静かなときに行う
        Ok(true) => restart_when_quiet(&app),
        Ok(false) => say(&app, format!("最新の版です（{}）", app.package_info().version)),
        Err(e) if e == BUSY => say(&app, "ちょうど確かめているところです"),
        Err(e) => { eprintln!("update: {e}"); say(&app, "アップデートを確かめられませんでした") }
    });
}

fn say(app: &AppHandle, text: impl Into<String>) { let _ = app.emit_to("main", "say", text.into()); }

/// Installs a newer version if there is one and announces it. Ok(true) only for the call that installed it,
/// so the periodic check and the menu never install or restart twice.
fn check(app: &AppHandle) -> Result<bool, String> {
    let _busy = CHECKING.try_lock().map_err(|_| BUSY.to_string())?;
    if READY.lock().unwrap().is_some() { return Ok(false); }
    let Some(version) = tauri::async_runtime::block_on(install(app)).map_err(|e| e.to_string())? else { return Ok(false) };
    // 入れ替える前に、キャラクターと大きな吹き出しが新しい版を伝える
    *READY.lock().unwrap() = Some(version.clone());
    let _ = app.emit("update-ready", version);
    Ok(true)
}

/// The newer version, once it is installed into the app bundle.
async fn install(app: &AppHandle) -> Result<Option<String>, Box<dyn std::error::Error>> {
    let Some(update) = app.updater()?.check().await? else { return Ok(None) };
    eprintln!("update: installing {}", update.version);
    update.download_and_install(|_, _| {}, || {}).await?;
    Ok(Some(update.version))
}

fn quiet(app: &AppHandle) -> bool {
    let open = ["panel", "settings"].iter().any(|label| {
        app.get_webview_window(label).and_then(|w| w.is_visible().ok()).unwrap_or(false)
    });
    !open && crate::idle_seconds() >= IDLE_BEFORE_RESTART
}

fn restart_when_quiet(app: &AppHandle) {
    while !quiet(app) { thread::sleep(RETRY_RESTART); }
    if let Err(e) = relaunch(app) { eprintln!("update: {e}"); }
}

/// `open -n` starts the new copy outside this process, so launchd does not take it down with us.
/// The new copy waits for this one's single-instance lock.
fn relaunch(app: &AppHandle) -> Result<(), String> {
    let bundle = crate::exe().ancestors().find(|p| p.extension().is_some_and(|e| e == "app"))
        .map(|p| p.to_path_buf()).ok_or("not running from an app bundle")?;
    match Command::new("open").arg("-n").arg(&bundle).status() {
        Ok(status) if status.success() => { app.exit(0); Ok(()) }
        result => Err(format!("could not restart: {result:?}")),
    }
}

/// The installed version waiting for a restart, if any.
#[tauri::command]
pub fn update_ready() -> Option<String> { READY.lock().unwrap().clone() }

/// The button in the large bubble: switch to the installed version now instead of waiting for a quiet moment.
#[tauri::command]
pub fn restart_now(app: AppHandle) -> Result<(), String> {
    if READY.lock().unwrap().is_none() { return Err("no update is waiting".into()); }
    relaunch(&app)
}

/// The version the app just moved to, once, so the character can say so after a restart.
/// A first install says nothing.
pub fn changed(previous: Option<&str>, current: &str) -> Option<String> {
    previous.filter(|p| *p != current).map(|_| current.to_string())
}

#[tauri::command]
pub fn just_updated(app: AppHandle) -> Option<String> {
    let current = app.package_info().version.to_string();
    let previous = crate::read_config().ok()?.get("version").and_then(|v| v.as_str().map(String::from));
    if previous.as_deref() != Some(current.as_str()) { let _ = crate::save_config("version", json!(current)); }
    changed(previous.as_deref(), &current)
}

#[cfg(test)]
mod tests {
    use super::changed;

    #[test]
    fn only_a_version_change_is_announced() {
        assert_eq!(changed(Some("0.1.5"), "0.1.6"), Some("0.1.6".into()));
        assert_eq!(changed(Some("0.1.6"), "0.1.6"), None);
        assert_eq!(changed(None, "0.1.6"), None);
    }
}
