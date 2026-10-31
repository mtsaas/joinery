//! The window's menu bar, as the Mac's (Joinery/App/JoineryApp.swift and CanvasCommands.swift): each item tells the
//! window its ID, in a `menu` event, and the window does it (desktop/src/menu.ts).

use tauri::menu::{Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::{App, Emitter, Manager, Runtime};

pub fn install<R: Runtime>(app: &App<R>) -> tauri::Result<()> {
    let handle = app.handle();
    let item = |id: &str, text: &str, accelerator: Option<&str>| MenuItem::with_id(handle, id, text, true, accelerator);
    let separator = || PredefinedMenuItem::separator(handle);

    let file = Submenu::with_items(handle, "&File", true, &[
        &item("new", "&New Data Model", Some("CmdOrCtrl+N"))?,
        &item("new-collection", "New &Collection", Some("CmdOrCtrl+Shift+N"))?,
        &separator()?,
        &item("import", "&Import Data Model…", Some("CmdOrCtrl+O"))?,
        &item("export", "&Export a Copy…", Some("CmdOrCtrl+Shift+E"))?,
        &item("add-examples", "Add E&xamples", None)?,
        &item("show-library", "Show &Library in Explorer", None)?,
        &separator()?,
        &item("save-version", "&Save Version", Some("CmdOrCtrl+S"))?,
        &item("history", "Version &History", Some("CmdOrCtrl+Shift+H"))?,
        &separator()?,
        &item("settings", "Se&ttings…", Some("CmdOrCtrl+,"))?,
        &separator()?,
        &item("close", "&Close", Some("CmdOrCtrl+W"))?,
    ])?;
    let edit = Submenu::with_items(handle, "&Edit", true, &[
        &item("undo", "&Undo", Some("CmdOrCtrl+Z"))?,
        &item("redo", "&Redo", Some(if cfg!(target_os = "macos") { "CmdOrCtrl+Shift+Z" } else { "CmdOrCtrl+Y" }))?,
        &separator()?,
        &item("cut", "Cu&t", Some("CmdOrCtrl+X"))?,
        &item("copy", "&Copy", Some("CmdOrCtrl+C"))?,
        &item("paste", "&Paste", Some("CmdOrCtrl+V"))?,
        &item("delete", "&Delete", None)?,
        &item("select-all", "Select &All", Some("CmdOrCtrl+A"))?,
    ])?;
    let view = Submenu::with_items(handle, "&View", true, &[
        &item("zoom-in", "Zoom &In", Some("CmdOrCtrl+="))?,
        &item("zoom-out", "Zoom &Out", Some("CmdOrCtrl+-"))?,
        &item("actual-size", "&Actual Size", Some("CmdOrCtrl+0"))?,
        &item("zoom-fit", "Zoom to &Fit", Some("CmdOrCtrl+1"))?,
    ])?;
    let help = Submenu::with_items(handle, "&Help", true, &[
        &item("connect-assistant", "Connect an &AI Assistant…", None)?,
        &separator()?,
        &item("about", "&About Joinery", None)?,
    ])?;
    // The Mac's first menu is the app's, whatever it's called; in development there, it gets one.
    #[cfg(target_os = "macos")]
    let menu = Menu::with_items(handle, &[
        &Submenu::with_items(handle, "Joinery", true, &[&PredefinedMenuItem::quit(handle, None)?])?,
        &file, &edit, &view, &help,
    ])?;
    #[cfg(not(target_os = "macos"))]
    let menu = Menu::with_items(handle, &[&file, &edit, &view, &help])?;
    app.set_menu(menu)?;
    app.on_menu_event(|app, event| {
        let id = event.id().as_ref();
        if id == "close" {
            // The window saves before it goes (desktop/src/menu.ts).
            let _ = app.emit("menu", "close");
        } else if let Some(window) = app.get_webview_window("main") {
            let _ = window.emit("menu", id);
        }
    });
    Ok(())
}
