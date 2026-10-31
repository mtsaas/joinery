//! Lets the app be checked from the command line, as the Mac's `App/DebugHooks.swift` does (scripts/smoke.sh drives
//! both). Debug builds only. Set in the environment:
//! - `JOINERY_OPEN=<name>`: open the model with that name.
//! - `JOINERY_SNAPSHOT=out.png`: after `JOINERY_SNAPSHOT_DELAY` seconds (2 by default), saves the canvas to `out.png`,
//!   prints what's open, and quits.

use base64::{engine::general_purpose::STANDARD, Engine};
use tauri::AppHandle;

#[derive(serde::Serialize)]
pub struct Hooks {
    open: Option<String>,
    snapshot: Option<String>,
    delay: f64,
}

#[tauri::command]
pub fn debug_hooks() -> Option<Hooks> {
    if !cfg!(debug_assertions) {
        return None;
    }
    let var = |name| std::env::var(name).ok();
    Some(Hooks {
        open: var("JOINERY_OPEN"),
        snapshot: var("JOINERY_SNAPSHOT"),
        delay: var("JOINERY_SNAPSHOT_DELAY").and_then(|d| d.parse().ok()).unwrap_or(2.0),
    })
}

#[tauri::command]
pub fn debug_snapshot(app: AppHandle, path: String, png: String, report: String) -> Result<(), String> {
    println!("{report}");
    if png.is_empty() {
        app.exit(1);
        return Ok(());
    }
    let bytes = STANDARD.decode(png).map_err(|e| e.to_string())?;
    std::fs::write(&path, bytes).map_err(|e| e.to_string())?;
    app.exit(0);
    Ok(())
}
