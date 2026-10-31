// Writes latest.json, the feed released copies check for updates (src/updates.ts), from a release's signed installers.
//   node scripts/update-feed.mjs <version> <download URL, without the file name> <folder of installers and .sig files>
// Each platform's installer is the one the updater installs: the NSIS setup on Windows, the AppImage on Linux.
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const [version, downloads, folder] = process.argv.slice(2);
if (!version || !downloads || !folder) throw new Error("Usage: update-feed.mjs <version> <download URL> <folder>");

const files = readdirSync(folder);
const platforms = {};
for (const [platform, pattern] of [["windows-x86_64", /-setup\.exe$/], ["linux-x86_64", /\.AppImage$/]]) {
  const installer = files.find((f) => pattern.test(f));
  if (!installer || !files.includes(`${installer}.sig`)) continue;
  platforms[platform] = {
    signature: readFileSync(join(folder, `${installer}.sig`), "utf8").trim(),
    url: `${downloads}/${encodeURIComponent(installer)}`,
  };
}
if (Object.keys(platforms).length === 0) throw new Error(`No signed installers in ${folder}.`);

const feed = { version, notes: `Joinery ${version}`, pub_date: new Date().toISOString(), platforms };
writeFileSync(join(folder, "latest.json"), JSON.stringify(feed, null, 2) + "\n");
console.log(`latest.json: ${Object.keys(platforms).join(", ")}`);
