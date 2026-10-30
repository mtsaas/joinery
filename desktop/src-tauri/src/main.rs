// Joinery for Windows and Linux: a window showing the app in desktop/src, which runs Joinery's core compiled to
// WebAssembly. This shell keeps the library on disk and listens for AI assistants.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod debug;
mod library;
mod mcp;
mod menu;

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .setup(|app| Ok(menu::install(app)?))
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .invoke_handler(tauri::generate_handler![
            library::list_library,
            library::read_model,
            library::write_model,
            library::create_model,
            library::rename_model,
            library::move_model,
            library::duplicate_model,
            library::trash_model,
            library::new_collection,
            library::set_favorite,
            library::mark_opened,
            library::set_baseline,
            library::import_model,
            library::reveal,
            library::list_versions,
            library::read_version,
            library::save_version,
            library::export_model,
            library::rename_collection,
            library::trash_collection,
            mcp::mcp_start,
            mcp::mcp_respond,
            mcp::mcp_stop,
            debug::debug_hooks,
            debug::debug_snapshot,
        ])
        .run(tauri::generate_context!())
        .expect("Joinery couldn't start");
}
