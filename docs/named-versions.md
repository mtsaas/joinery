# Named versions and arbitrary comparisons

Status: implemented on the Mac. Replaces the single review baseline.

## Problem

A data model can only hold one baseline (`baseline.json`). `mark_baseline` overwrites it and `get_changes` only reports
baseline → now. A common review needs more: "main → first draft", "first draft → now" and "main → now" for a PR that was
updated. You can't do that today without drawing the same schema again in several separate review models.

## Decision

Let a model keep any number of **named versions**. Add a **compare** that takes any two of them, with `current` as the
live model. Remove `mark_baseline` and `get_changes`: they're special cases of the new tools, and two ways to do the same
thing confuse an assistant.

The diff engine already handles this. `SchemaDiff(from:to:)` takes any two `DataModel`s and matches tables and columns by
ID, and every version of a model keeps the same IDs. So "main → current" still shows a rename made in draft 1 as a rename.
Only the storage, the tools and the comparison bar change.

## Tools

| Tool | Arguments | Does |
|---|---|---|
| `save_version` | `name`, `replace?` (default false) | Saves the current model under `name`. Fails if the name is already used, unless `replace` is set. |
| `list_versions` | none | Lists each named version: name, when it was saved, table count, and a one-line summary of changes from the previous named version. Also says how `current` relates to them: "current is the same as draft 2" or "current: 3 changes since draft 2". |
| `compare` | `from`, `to` | Both are a version name or `current`. Returns the `SchemaDiff` report headed `main → draft 1: …`, and shows that comparison in the window. |
| `restore_version` | `name`, `discard_unsaved?` | Makes the current model equal to that version. The change can be undone, and a history version is kept first, as `OpenModel.restore` already does. Refuses if `current` has changes that aren't in any named version, unless `discard_unsaved` is set. |
| `delete_version` | `name` | Deletes a named version. |
| `get_model` | `version?` (new, optional) | Reads a named version without restoring it. |

`start_review` stays the same. The review steps become:
`start_review` → `create_tables` (the before schema) → `arrange` → `save_version("main")`, named after the base branch →
make the change → `compare("main", "current")`.

The PR-updated case from the prompt, starting from a review whose baseline is main and whose current state is the first
draft:

```
save_version("draft 1")                 # current is still the first draft
…editing tools: apply the PR's new commits…
save_version("draft 2")                 # optional: freezes it
compare("main", "draft 1")
compare("draft 1", "current")
compare("main", "current")
```

### Why this shape suits an assistant

- **It works like git.** Names act like refs, `compare` is `git diff a b`, and `restore_version` is checkout. Models
  already understand that, including branching: from `main`, try alternative designs A and B, save each one, then compare
  A with B.
- **Calls don't depend on hidden state.** Every `compare` names both ends, so there's no current baseline to keep track
  of. The calls still work after context compaction or in a new session, which `get_changes` doesn't.
- **There's one way to do each thing.** No overlap between `mark_baseline` and `save_version`.
- **Orienting takes one call.** `list_versions` tells a fresh agent what exists and where `current` stands.
- **Errors say what to call next.** For example: `There's no version called "draft1". Versions: main, draft 1, draft 2.`
  or `current has changes not in any named version: save_version first, or pass discard_unsaved: true.`
- **Results echo state.** `save_version` returns the full list of names, so the agent rarely needs a follow-up read.

### Names

Names are trimmed and matched case-insensitively. `current` is reserved. `/` and `:` are replaced, as `start_review`
already does for titles. Names are unique within a model.

## Storage

Everything is in one file in the `.joinery` package, `named-versions.json`, so it travels with the model: each version's
name, when it was saved (to the second) and the whole model, oldest first, and the comparison the window shows
(`{"from": "main", "to": "current"}`), so a comparison survives quitting. One file keeps the order explicit and lets
names hold any characters. It replaces `baseline.json`, and is removed when there are no versions and no comparison.

**Migration:** a package opened with a `baseline.json` gets it as the named version `Before`, compared with `current`,
and the old file is deleted.

## Window

- `ComparisonBar` gets **From** and **To** menus (the named versions plus Now), next to the existing Before / Changes /
  After control. The person can flip between the same pairs the agent compared.
- The Version History popover gets a **Named** section at the top. Picking one shows it compared with now, as the dated
  versions do.
- While comparing (named versions, or a version from the version history), the person can lay out what's shown:
  move tables, tie wires, change table and group colors, use the Layout menu, but not change the schema: cells can't be edited, the designer opens read-only, and the palette and wheel leave out
  commands that would change it. Each
  change goes straight into the version it's made in: Before is the From version, After the To version, and in
  Changes a table is the To version's unless it was removed since, when it's the From version's. A named version is
  rewritten in `named-versions.json` (keeping its date and place), a history version's file is written over, and Now
  is the model itself, which can be undone. Assistant edits still apply to `current`, and the diff follows them live
  when one end is `current`.
- End Review becomes **End Comparison**: it clears the comparison and keeps the named versions.

## Code

- `Document/NamedVersions.swift`: the versions and comparison, name matching, and the file format.
- `MCP/Protocol/VersionTools.swift`: the tools, written once against `VersionState` (the open model and its named
  versions). `MCPHost.withVersions` hands them that state and keeps what they change.
- `MCP/Protocol/MCP.swift`: routing, the tool list, the server instructions and the review prompt.
- `Library/OpenModel.swift`: `named`, reading and writing the file, the migration, `compare` and `endComparison`.
- `MCP/MCPServer.swift`: the Mac's `withVersions`.
- `Library/LibraryView.swift` and `VersionHistory.swift`: the comparison bar's From and To menus, and the Named section.

The Windows and Linux app (on `windows-app`) shares `MCP/Protocol` and `Document`, so it needs its own `withVersions`
and the storage in its shell before it can merge with this.

## Tests

- History: named versions round-trip, survive thinning, and `replace` behaves as described.
- Migration: opening with `baseline.json` creates `Before` and the comparison.
- Three versions, with a column renamed in draft 1 and a table added in draft 2: `main → current` shows one rename and
  one addition, not a drop and an add.
- Tools: `compare` with an unknown name lists the known names, and `restore_version` refuses unsaved work.
- Update the existing tool-list and prompt-step expectations in `JoineryTests.swift`.

## Not included

- **Sharing named versions in a live session.** They're stored per package, so guests don't see them. Add them when
  someone needs this.
- **Saving a named version from the window.** Only assistants save them for now.
- **`rename_version`.** Save under the new name and delete the old one instead.
- **Three-way or merge views.** Every comparison is between two versions.
