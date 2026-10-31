// Mascot for desk-steward: a transparent always-on-top character, a speech bubble that follows it,
// and a large speech bubble with the suggestions. It only reads live.json; every state change goes through the steward CLI.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
use std::{path::PathBuf, process::Command};
use tauri::{AppHandle, Emitter, LogicalSize, Manager, PhysicalPosition, PhysicalSize, WebviewWindow, WindowEvent};

const BUBBLE_OVERLAP: f64 = 110.0; // logical px the bubble overlaps the mascot window, so the tail reaches her
const BUBBLE_GAP: f64 = 12.0; // logical px between the bubble and the bottom screen edge
const PANEL_WIDTH: f64 = 500.0;

fn home() -> PathBuf { PathBuf::from(std::env::var("HOME").unwrap_or_default()) }

fn state_dir() -> PathBuf {
    std::env::var("DESK_STEWARD_STATE").map(PathBuf::from)
        .unwrap_or_else(|_| home().join(".local/state/desk-steward"))
}

fn steward_bin() -> PathBuf {
    std::env::var("STEWARD_BIN").map(PathBuf::from)
        .unwrap_or_else(|_| home().join(".local/bin/steward"))
}

#[tauri::command]
fn quit(app: AppHandle) { app.exit(0); }

#[tauri::command]
fn log(msg: String) { eprintln!("[page] {msg}"); }

#[tauri::command]
fn qa_flags() -> String { std::env::var("MASCOT_QA").unwrap_or_default() }

#[tauri::command]
fn live() -> String {
    std::fs::read_to_string(state_dir().join("live.json")).unwrap_or_else(|_| "{}".into())
}

/// Runs the steward CLI. Accepting takes seconds, so this stays off the main thread.
#[tauri::command]
async fn steward(args: Vec<String>) -> Result<String, String> {
    const ALLOWED: [&str; 4] = ["list", "accept", "dismiss", "snooze"];
    if !args.first().is_some_and(|c| ALLOWED.contains(&c.as_str())) {
        return Err("command not allowed".into());
    }
    tauri::async_runtime::spawn_blocking(move || {
        let out = Command::new(steward_bin()).args(&args).output().map_err(|e| e.to_string())?;
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
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![quit, log, qa_flags, live, steward, open_url, bubble, show_panel, fit_panel, hide_panel])
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
