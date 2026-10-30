//! The library: `.joinery` packages in a folder, whose subfolders are collections, the same files the Mac app keeps
//! (Joinery/Library/Library.swift and History.swift). A package is a folder holding `model.json`, its earlier versions in
//! `Versions/`, and a review's `baseline.json`; a model from before packages is the JSON alone, and becomes a package
//! when next written. Paths to and from the window are relative to the library's folder.
//!
//! The Mac keeps favorites and when each was last opened in extended attributes; here they're in `.library.json`.

use chrono::{DateTime, Local, NaiveDateTime, TimeZone};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::path::{Component, Path, PathBuf};

type Result<T> = std::result::Result<T, String>;

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

/// Where the library is: Joinery in the person's Documents.
pub fn root() -> PathBuf {
    std::env::var_os("JOINERY_LIBRARY")
        .map(PathBuf::from)
        .unwrap_or_else(|| dirs::document_dir().unwrap_or_else(|| PathBuf::from(".")).join("Joinery"))
}

/// A path from the window, inside the library, or an error.
fn resolve(relative: &str) -> Result<PathBuf> {
    let path = Path::new(relative);
    if path.components().any(|c| !matches!(c, Component::Normal(_))) {
        return Err(format!("“{relative}” isn't in the library."));
    }
    Ok(root().join(path))
}

fn relative(path: &Path) -> String {
    path.strip_prefix(root()).unwrap_or(path).to_string_lossy().replace('\\', "/")
}

fn is_model(path: &Path) -> bool {
    path.extension().is_some_and(|e| e == "joinery")
}

fn name_of(path: &Path) -> String {
    path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
}

// MARK: Marks

#[derive(Serialize, Deserialize, Default)]
struct Marks {
    #[serde(default)]
    favorites: HashSet<String>,
    #[serde(default)]
    opened: HashMap<String, f64>,
}

fn marks_path() -> PathBuf {
    root().join(".library.json")
}

fn marks() -> Marks {
    fs::read(marks_path()).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()
}

fn save_marks(marks: &Marks) -> Result<()> {
    fs::write(marks_path(), serde_json::to_vec_pretty(marks).map_err(err)?).map_err(err)
}

/// Marks follow a model when it's renamed or moved.
fn move_marks(from: &str, to: &str) -> Result<()> {
    let mut m = marks();
    if m.favorites.remove(from) {
        m.favorites.insert(to.to_string());
    }
    if let Some(opened) = m.opened.remove(from) {
        m.opened.insert(to.to_string(), opened);
    }
    save_marks(&m)
}

// MARK: Listing

#[derive(Serialize)]
pub struct ModelEntry {
    path: String,
    name: String,
    collection: Option<String>,
    favorite: bool,
    opened: Option<f64>,
}

#[derive(Serialize)]
pub struct Listing {
    root: String,
    models: Vec<ModelEntry>,
    collections: Vec<String>,
}

#[tauri::command]
pub fn list_library() -> Result<Listing> {
    let root = root();
    fs::create_dir_all(&root).map_err(err)?;
    let marks = marks();
    let mut models = vec![];
    let mut collections = vec![];
    let entry = |path: &Path, collection: Option<String>| {
        let rel = relative(path);
        ModelEntry {
            name: name_of(path),
            collection,
            favorite: marks.favorites.contains(&rel),
            opened: marks.opened.get(&rel).copied(),
            path: rel,
        }
    };
    let mut top: Vec<_> = fs::read_dir(&root).map_err(err)?.flatten().map(|e| e.path()).collect();
    top.sort_by_key(|p| name_of(p).to_lowercase());
    for path in top {
        let hidden = path.file_name().is_some_and(|n| n.to_string_lossy().starts_with('.'));
        if hidden {
            continue;
        }
        if is_model(&path) {
            models.push(entry(&path, None));
        } else if path.is_dir() {
            let name = path.file_name().unwrap().to_string_lossy().into_owned();
            let mut inside: Vec<_> = fs::read_dir(&path).map_err(err)?.flatten().map(|e| e.path()).filter(|p| is_model(p)).collect();
            inside.sort_by_key(|p| name_of(p).to_lowercase());
            for model in inside {
                models.push(entry(&model, Some(name.clone())));
            }
            collections.push(name);
        }
    }
    Ok(Listing { root: root.to_string_lossy().into_owned(), models, collections })
}

// MARK: Reading and writing

fn model_file(package: &Path) -> PathBuf {
    if package.is_dir() { package.join("model.json") } else { package.to_path_buf() }
}

#[derive(Serialize)]
pub struct Opened {
    model: String,
    baseline: String,
}

#[tauri::command]
pub fn read_model(path: String) -> Result<Opened> {
    let package = resolve(&path)?;
    let model = fs::read_to_string(model_file(&package)).map_err(|e| format!("Couldn't open “{}”: {e}", name_of(&package)))?;
    let baseline = fs::read_to_string(package.join("baseline.json")).unwrap_or_default();
    Ok(Opened { model, baseline })
}

/// Written whole to a new file that then replaces the old, so it's never half written.
fn write_atomically(path: &Path, contents: &str) -> Result<()> {
    let temporary = path.with_extension("json.saving");
    fs::write(&temporary, contents).map_err(err)?;
    fs::rename(&temporary, path).map_err(err)
}

/// Makes a model from before packages into one, keeping its JSON as its model.
fn ensure_package(package: &Path) -> Result<()> {
    if package.is_file() {
        let model = fs::read(package).map_err(err)?;
        fs::remove_file(package).map_err(err)?;
        fs::create_dir_all(package).map_err(err)?;
        fs::write(package.join("model.json"), model).map_err(err)?;
    }
    Ok(())
}

#[tauri::command]
pub fn write_model(path: String, model: String) -> Result<()> {
    let package = resolve(&path)?;
    // Not if it's gone (moved or deleted), so a late save can't bring it back.
    if !package.exists() {
        return Ok(());
    }
    ensure_package(&package)?;
    write_atomically(&package.join("model.json"), &model)
}

/// `name`, or `name 2`, `name 3`… so as not to replace anything already in `folder`.
fn unique(folder: &Path, name: &str, extension: Option<&str>) -> PathBuf {
    let with = |n: &str| folder.join(extension.map_or(n.to_string(), |e| format!("{n}.{e}")));
    let mut candidate = with(name);
    let mut n = 2;
    while candidate.exists() {
        candidate = with(&format!("{name} {n}"));
        n += 1;
    }
    candidate
}

/// Names can't hold these on Windows, nor `:` or `/` on the Mac.
fn clean(name: &str) -> String {
    let cleaned: String = name.chars().map(|c| if "\\/:*?\"<>|".contains(c) { '-' } else { c }).collect();
    let trimmed = cleaned.trim().trim_end_matches('.').to_string();
    if trimmed.is_empty() { "Untitled Data Model".into() } else { trimmed }
}

fn folder_of(collection: Option<String>) -> Result<PathBuf> {
    let folder = match collection {
        Some(c) => resolve(&clean(&c))?,
        None => root(),
    };
    fs::create_dir_all(&folder).map_err(err)?;
    Ok(folder)
}

#[tauri::command]
pub fn create_model(collection: Option<String>, name: String, model: String) -> Result<String> {
    let package = unique(&folder_of(collection)?, &clean(&name), Some("joinery"));
    fs::create_dir_all(&package).map_err(err)?;
    fs::write(package.join("model.json"), model).map_err(err)?;
    Ok(relative(&package))
}

fn relocate(path: &str, to: PathBuf) -> Result<String> {
    fs::rename(resolve(path)?, &to).map_err(err)?;
    let new = relative(&to);
    move_marks(path, &new)?;
    Ok(new)
}

#[tauri::command]
pub fn rename_model(path: String, name: String) -> Result<String> {
    let from = resolve(&path)?;
    let folder = from.parent().unwrap().to_path_buf();
    if name_of(&from) == clean(&name) {
        return Ok(path);
    }
    relocate(&path, unique(&folder, &clean(&name), Some("joinery")))
}

#[tauri::command]
pub fn move_model(path: String, collection: Option<String>) -> Result<String> {
    let name = name_of(&resolve(&path)?);
    relocate(&path, unique(&folder_of(collection)?, &name, Some("joinery")))
}

fn copy_all(from: &Path, to: &Path) -> std::io::Result<()> {
    if from.is_dir() {
        fs::create_dir_all(to)?;
        for entry in fs::read_dir(from)? {
            let entry = entry?;
            copy_all(&entry.path(), &to.join(entry.file_name()))?;
        }
        Ok(())
    } else {
        fs::copy(from, to).map(|_| ())
    }
}

#[tauri::command]
pub fn duplicate_model(path: String) -> Result<String> {
    let from = resolve(&path)?;
    let copy = unique(from.parent().unwrap(), &format!("{} copy", name_of(&from)), Some("joinery"));
    copy_all(&from, &copy).map_err(err)?;
    Ok(relative(&copy))
}

/// To the Recycle Bin (the Trash, on Linux), so it can be got back.
#[tauri::command]
pub fn trash_model(path: String) -> Result<()> {
    trash::delete(resolve(&path)?).map_err(err)
}

#[tauri::command]
pub fn new_collection(name: String) -> Result<String> {
    let folder = unique(&root(), &clean(&name), None);
    fs::create_dir_all(&folder).map_err(err)?;
    Ok(relative(&folder))
}

#[tauri::command]
pub fn set_favorite(path: String, favorite: bool) -> Result<()> {
    let mut m = marks();
    if favorite { m.favorites.insert(path); } else { m.favorites.remove(&path); }
    save_marks(&m)
}

#[tauri::command]
pub fn mark_opened(path: String) -> Result<()> {
    let mut m = marks();
    m.opened.insert(path, Local::now().timestamp_millis() as f64);
    save_marks(&m)
}

/// A review's baseline, kept in the package so the review survives quitting; "" ends it.
#[tauri::command]
pub fn set_baseline(path: String, model: String) -> Result<()> {
    let package = resolve(&path)?;
    ensure_package(&package)?;
    let file = package.join("baseline.json");
    if model.is_empty() {
        let _ = fs::remove_file(file);
        Ok(())
    } else {
        write_atomically(&file, &model)
    }
}

/// A `.joinery` file or folder from elsewhere, copied into the library.
#[tauri::command]
pub fn import_model(source: String) -> Result<String> {
    let from = PathBuf::from(&source);
    let copy = unique(&root(), &name_of(&from), Some("joinery"));
    copy_all(&from, &copy).map_err(err)?;
    Ok(relative(&copy))
}

#[tauri::command]
pub fn reveal(path: String) -> Result<()> {
    let target = resolve(&path)?;
    tauri_plugin_opener::reveal_item_in_dir(target).map_err(err)
}

// MARK: Versions

/// As the Mac's: each version is the model's JSON, named for when it was saved and why.
const STAMP: &str = "%Y-%m-%d %H.%M.%S%.3f";
const STAMP_LENGTH: usize = 23;
/// Why a version saved with Ctrl+S was: those are never thinned out.
const SAVED: &str = "Saved";

#[derive(Serialize, Clone)]
pub struct Version {
    file: String,
    date: f64,
    reason: String,
    #[serde(rename = "isReview")]
    is_review: bool,
}

fn versions_in(folder: &Path) -> Vec<(Version, DateTime<Local>)> {
    let Ok(entries) = fs::read_dir(folder) else { return vec![] };
    let files: Vec<PathBuf> = entries.flatten().map(|e| e.path()).collect();
    let befores: HashSet<String> = files.iter().filter(|p| p.extension().is_some_and(|e| e == "before")).map(|p| name_of(p)).collect();
    let mut versions: Vec<_> = files
        .iter()
        .filter(|p| p.extension().is_some_and(|e| e == "json"))
        .filter_map(|p| {
            let name = name_of(p);
            let stamp = name.get(..STAMP_LENGTH)?;
            let date = Local.from_local_datetime(&NaiveDateTime::parse_from_str(stamp, STAMP).ok()?).single()?;
            let version = Version {
                file: p.file_name()?.to_string_lossy().into_owned(),
                date: date.timestamp_millis() as f64,
                reason: name.get(STAMP_LENGTH + 1..).unwrap_or("").to_string(),
                is_review: befores.contains(&name),
            };
            Some((version, date))
        })
        .collect();
    versions.sort_by(|a, b| b.1.cmp(&a.1));
    versions
}

#[tauri::command]
pub fn list_versions(path: String) -> Result<Vec<Version>> {
    Ok(versions_in(&resolve(&path)?.join("Versions")).into_iter().map(|(v, _)| v).collect())
}

#[derive(Serialize)]
pub struct VersionContents {
    model: String,
    before: Option<String>,
}

#[tauri::command]
pub fn read_version(path: String, file: String) -> Result<VersionContents> {
    if file.contains(['/', '\\']) {
        return Err("No such version.".into());
    }
    let url = resolve(&path)?.join("Versions").join(&file);
    let model = fs::read_to_string(&url).map_err(|_| "That version is gone.".to_string())?;
    let before = fs::read_to_string(url.with_extension("before")).ok();
    Ok(VersionContents { model, before })
}

/// Saves `model` as a version, unless it's the same as the latest, then thins out old ones. With `before`, it's a
/// review's, kept always. Returns whether it was saved.
#[tauri::command]
pub fn save_version(path: String, reason: String, model: String, before: Option<String>) -> Result<bool> {
    let package = resolve(&path)?;
    if !package.exists() {
        return Ok(false);
    }
    ensure_package(&package)?;
    let folder = package.join("Versions");
    let existing = versions_in(&folder);
    if let (None, Some((latest, _))) = (&before, existing.first()) {
        if !latest.is_review && fs::read_to_string(folder.join(&latest.file)).ok().as_deref() == Some(model.as_str()) {
            return Ok(false);
        }
    }
    // Always after the latest, so they sort in the order they were saved.
    let mut now = Local::now();
    if let Some((_, latest)) = existing.first() {
        if now <= *latest {
            now = *latest + chrono::Duration::milliseconds(1);
        }
    }
    fs::create_dir_all(&folder).map_err(err)?;
    let reason = clean(&reason);
    let url = folder.join(format!("{} {reason}.json", now.format(STAMP)));
    if let Some(before) = &before {
        fs::write(url.with_extension("before"), before).map_err(err)?;
    }
    fs::write(&url, &model).map_err(err)?;
    let versions = versions_in(&folder);
    let dates: Vec<_> = versions.iter().map(|(_, d)| *d).collect();
    let kept = kept(&dates, now);
    for (index, (version, _)) in versions.iter().enumerate() {
        if !kept.contains(&index) && version.reason != SAVED && !version.is_review {
            let _ = fs::remove_file(folder.join(&version.file));
        }
    }
    Ok(true)
}

/// Which of `dates` (newest first) to keep: all from the last two days; then the earliest of each day for a month;
/// then the earliest of each week.
fn kept(dates: &[DateTime<Local>], now: DateTime<Local>) -> HashSet<usize> {
    use chrono::Datelike;
    let mut kept = HashSet::new();
    let mut earliest: BTreeMap<(i32, u32, u32), usize> = BTreeMap::new();
    for (index, date) in dates.iter().enumerate() {
        let age = (now - *date).num_seconds();
        if age < 2 * 24 * 3600 {
            kept.insert(index);
            continue;
        }
        let bucket = if age < 30 * 24 * 3600 {
            (date.year(), date.month(), date.day())
        } else {
            let week = date.iso_week();
            (week.year(), 100 + week.week(), 0)
        };
        // Newest first, so the last one seen is the earliest.
        earliest.insert(bucket, index);
    }
    kept.extend(earliest.values());
    kept
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn thinning_keeps_recent_then_daily_then_weekly() {
        let now = Local::now();
        let hours = |h: i64| now - chrono::Duration::hours(h);
        // Two today; two on one day a week ago, of which the earlier stays; one long ago.
        let dates = vec![hours(1), hours(3), hours(24 * 7), hours(24 * 7 + 2), hours(24 * 90)];
        let kept = kept(&dates, now);
        assert!(kept.contains(&0) && kept.contains(&1));
        assert!(kept.contains(&3) && !kept.contains(&2));
        assert!(kept.contains(&4));
    }

    #[test]
    fn paths_stay_inside_the_library() {
        assert!(resolve("../secrets").is_err());
        assert!(resolve("/etc/passwd").is_err());
        assert!(resolve("Examples/Sakila.joinery").is_ok());
    }

    #[test]
    fn names_are_cleaned() {
        assert_eq!(clean("PR 482: refunds"), "PR 482- refunds");
        assert_eq!(clean("  "), "Untitled Data Model");
    }
}
