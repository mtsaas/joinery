// Updates from GitHub, as the Mac's come through Sparkle: once at launch, the feed on the `desktop-updates` release
// (latest.json, signed with the updater key) is checked, and a newer version is offered, installed and restarted into.
// Copies run from source (`tauri dev`) don't check.
import { relaunch } from "@tauri-apps/plugin-process";
import { check } from "@tauri-apps/plugin-updater";
import { isApp } from "./library.ts";
import { saveNow } from "./store.ts";

export async function checkForUpdates() {
  if (!isApp || import.meta.env.DEV) return;
  try {
    const update = await check();
    if (!update) return;
    if (!confirm(`Joinery ${update.version} is available (you have ${update.currentVersion}). Install it and restart?`)) return;
    await saveNow();
    await update.downloadAndInstall();
    await relaunch();
  } catch (error) {
    // No feed yet, offline, or no updater key in this build: nothing to offer.
    console.info("No update:", error);
  }
}
