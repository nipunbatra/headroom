# Headroom

A standalone Mac storage analyser and cleaner (in the spirit of CleanMyMac / DaisyDisk / Mole).
It runs without Claude: open Headroom, it scans, you click Clean. The app is native SwiftUI
(sidebar, toolbar, menus, menu bar item) on top of a Python scanner that it runs as a local helper.

## Pieces

- `scan.py`: Python standard library only, two modes.
  - `python3 scan.py`: read-only scan of `/System/Volumes/Data` (about 3 minutes for 6.7M files)
    that writes `scan.json`. Never deletes anything.
  - `python3 scan.py app`: local server on 127.0.0.1 that serves the UI and carries out cleanups
    confirmed in it. `--no-open` skips opening a window, `--port 0` picks a free port, `--stay`
    ties its life to the parent process, `--out` sets where `scan.json` and the action log live.
- `index.html`: the whole UI in one file, vanilla JS, no build step. `window.HEADROOM.token`
  (injected by the server) switches it into app mode with Clean buttons and Scan again. Without
  it the page is a read-only snapshot that only builds a script; that is what the claude.ai
  artifact shows. No doctype/html/head/body tags: the server and the artifact host add them.
- `app/Sources/*.swift`: the native SwiftUI app (macOS 14+), compiled by `build.sh` with plain
  `swiftc`. It starts `scan.py app --stay --port 0`, reads the `HEADROOM_TOKEN` and `HEADROOM_URL`
  lines from the pipe, and talks to that helper (`Engine.swift`). It reads `scan.json` from disk.
  - `AppModel.swift`: all state (`@Observable`): the scan, candidates, the cleanup list (`plan`),
    the clean session, live free space, alerts. `Rows.swift` turns the scan into one `Row` shape
    for every page; `RowList.swift` draws it (selection, context menu, Space, Delete).
  - `Shell.swift` (window, sidebar, toolbar, scanning, What Changed), `Overview.swift` (level
    meter, cards, chart), `MapView.swift` (treemap), `CleanSheet.swift` (cleanup list inspector and
    the review sheet), `MenuBar.swift` (menu bar item, Settings), `App.swift` (scenes, menus,
    snapshot and self-test modes).
  - Views are marked `@MainActor`: the toolchain here is Swift 5.9, where only `body` is isolated.
  - A plain `VStack` of text above a `List` as a page root rendered a blank window once (What
    Changed). Put page summaries in the list via `RowList(header:)` instead.
- `app/make_icon.swift` draws the icon.
- `build.sh`: compiles a universal binary, copies `scan.py` and `index.html` into
  `dist/Headroom.app/Contents/Resources`, makes the icon, ad-hoc signs, and zips it to
  `dist/Headroom.zip`. `--debug` is a quick local build; `--install` moves the app into
  `/Applications` (quitting a running copy first). Rebuild after any edit.
- `HEADROOM_SNAPSHOT=<dir>` makes the app save a PNG of every page in light and dark and quit (it
  captures its own window, so no Screen Recording permission is needed). `HEADROOM_SELFTEST=<ids>`
  cleans fixture ids through the real model code; it refuses ids that are not fixtures.
- `index.html` is the earlier web UI. It still works (`python3 scan.py app`) and is what the
  claude.ai artifact shows, but new features go into the native app first.
- Never share or commit `scan.json`: it lists this Mac's folder and file names.
- The app keeps its data in `~/Library/Application Support/Headroom/` (`scan.json`,
  `headroom-actions.log`). Dev mode (`python3 scan.py app`) uses this folder instead.

## Safety rules to keep

- The page only ever sends item ids. `resolve()` in `scan.py` decides what an id means from the
  `RULES` table; a command or path invented by the page is never run.
- Free-form paths must pass `user_path_ok()`: under `~`, two levels deep (three under
  `~/Library`), never `.git`, never through a symlink; or `/Applications/*.app`.
  `pickable()` in `index.html` mirrors it. Change both together.
- Caches and rebuildable folders (`node_modules`, `target`, ...) are deleted outright; everything
  else goes to the Trash unless the user ticks "skip the Trash".
- Every API call needs the per-launch token plus a 127.0.0.1/localhost Host and Origin.
- Three safety levels drive the UI: `safe`, `review`, `keep`. A rule `cmd` of `@manual` means
  "not automatable, handle in the owning app".
- Paths in `scan.json` use `~` so a shared snapshot carries no account name.
- Test deletion only on throwaway fixtures (see how `_fixture/` was used), never on real data.

## Deeper views

- `rule_items()` lists the independent pieces inside a rule (`ITEM_LEVELS` says where they
  live). Items carry `seen` (newest read or write) and `changed` (newest write). macOS moves
  read times forward only occasionally and backups count as reads, so the UI calls it a hint.
- Hugging Face hubs (`HF_HUBS`) link repos into a shared blob store. `hfrepo:` ids delete a repo
  plus the blobs only it uses; `hforphans:` deletes blobs nothing links to. Both are worked out
  on the server at delete time, never taken from the page.
- `/api/list` returns one folder's live contents (home folder only, read-only, 6 second budget);
  `/api/reveal` shows an item in Finder. "Look inside" in the UI is built on these.
- Rules in `PERMANENT` are download caches: removed outright, like other caches.

## History, what changed, uninstalling

- Each scan is compared with the one it replaces: `diff_trees()` reports the deepest folders that
  explain the change, using returnable sizes (`r`) so a fresh clone of something already on disk
  is not growth. The result is `changes` in `scan.json`. `history.json` (numbers only) keeps free
  space per scan plus one reading every 3 hours from `/api/history`.
- `app:` ids uninstall an app. Only bundles directly in `/Applications` or `~/Applications` with a
  real `Contents/Info.plist` qualify. `app_leftovers()` adds paths from `LEFTOVER_SPOTS` that
  carry the app's bundle id (three parts or more) or exact name, pass `user_path_ok()`, and are
  reached without a symlink. An id or name used by two installed apps, or a vendor folder name,
  is never matched. A running app is refused. All of this is decided on the server at delete time.

## Sizes: on disk versus what deleting returns

- `read_dir()` uses `getattrlistbulk` (one call per folder: name, type, mtime, flags, id, link
  count, allocated size, length, clone id, extended flags). It falls back to `os.scandir` if the
  file system refuses. Verified against `lstat` entry by entry; mounted volumes and cloud
  placeholders are flagged so the walk never enters them.
- Only files with `EF_MAY_SHARE_BLOCKS` are asked for `ATTR_CMNEXT_PRIVATESIZE` and
  `ATTR_CMNEXT_CLONE_REFCNT` (`clone_info()`), because that call is the slow one. Checked on
  970k files: no file without the flag shares anything.
- A clone group's shared bytes are credited to the deepest folder that holds every copy, and
  only if the copies seen equal the copy count macOS reports. So `frees` for a folder is exact:
  private bytes plus shared bytes of groups that live entirely inside it.
- JSON: `bytes` is size on disk, `frees` appears only when smaller. Tree nodes use `s` and `r`.
  `disk.unique` is the scanned total with shared space counted once. The UI's `fr()` reads it;
  plan totals, the safe/review sums and the big Clean button all use the returnable figure.
- Never walk a folder without the cloud-placeholder skip: listing a dataless folder makes macOS
  fetch it. A profiling script did this once in `~/Library`.

## Known gaps

- Still needs a Python 3 on the machine (Homebrew or the Xcode Command Line Tools). A Swift
  scanner would remove that.
- Without Full Disk Access, `~/.Trash`, Mail, Messages and Photos internals are unreadable.
- Ad-hoc signed, not notarised: fine on the Mac that built it, Gatekeeper will object elsewhere.
- Spotlight has no index on this disk, so app last-opened dates are missing.
