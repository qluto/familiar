// Updates the installed app from GitHub Releases. The download and the install happen in the background;
// the restart waits for a quiet moment, so a conversation or a settings change is never cut off.
use std::{process::Command, thread, time::Duration};
use serde_json::json;
use tauri::{AppHandle, Manager};
use tauri_plugin_updater::UpdaterExt;

const FIRST_CHECK: Duration = Duration::from_secs(60);
const CHECK_EVERY: Duration = Duration::from_secs(6 * 3600);
const RETRY_RESTART: Duration = Duration::from_secs(60);
/// No keyboard or mouse input for this long counts as away.
const IDLE_BEFORE_RESTART: f64 = 120.0;

/// Only the app in /Applications updates itself. A dev build or an app still running from the dmg would
/// replace the wrong copy.
pub fn start(app: AppHandle) {
    if !crate::exe().starts_with("/Applications") { return; }
    thread::spawn(move || {
        thread::sleep(FIRST_CHECK);
        loop {
            match tauri::async_runtime::block_on(install(&app)) {
                Ok(true) => return restart_when_quiet(&app),
                Ok(false) => {}
                Err(e) => eprintln!("update: {e}"),
            }
            thread::sleep(CHECK_EVERY);
        }
    });
}

/// True when a newer version was installed into the app bundle.
async fn install(app: &AppHandle) -> Result<bool, Box<dyn std::error::Error>> {
    let Some(update) = app.updater()?.check().await? else { return Ok(false) };
    eprintln!("update: installing {}", update.version);
    update.download_and_install(|_, _| {}, || {}).await?;
    Ok(true)
}

fn quiet(app: &AppHandle) -> bool {
    let open = ["panel", "settings"].iter().any(|label| {
        app.get_webview_window(label).and_then(|w| w.is_visible().ok()).unwrap_or(false)
    });
    !open && crate::idle_seconds() >= IDLE_BEFORE_RESTART
}

/// `open -n` starts the new copy outside this process, so launchd does not take it down with us.
/// The new copy waits for this one's single-instance lock.
fn restart_when_quiet(app: &AppHandle) {
    while !quiet(app) { thread::sleep(RETRY_RESTART); }
    let Some(bundle) = crate::exe().ancestors().find(|p| p.extension().is_some_and(|e| e == "app")).map(|p| p.to_path_buf()) else { return };
    match Command::new("open").arg("-n").arg(&bundle).status() {
        Ok(status) if status.success() => app.exit(0),
        result => eprintln!("update: could not restart: {result:?}"),
    }
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
