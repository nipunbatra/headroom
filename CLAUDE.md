# Headroom

A standalone Mac storage analyser and cleaner (in the spirit of CleanMyMac / DaisyDisk / Mole).
It runs without Claude: open Headroom, it scans, you click Clean. Everything is Swift: a SwiftUI
app (sidebar, toolbar, menus, menu bar item) with its own scanner and cleaner in the same process.
No Python, no helper process, no network.

## Pieces

- `app/Engine/*.swift`: the engine. Foundation only, no UI, so the tests can compile it alone.
  - `Env.swift`: where "this Mac" lives (home, support folder, app folders, the Trash function).
    All engine code goes through an `Env`, so tests point it at a throwaway home.
  - `Rules.swift`: the table of known places (`Rules.table`) and the other lists (item levels,
    leftover spots, opaque suffixes, kinds). Generated once from the old `scan.py`; this file is
    now the source of truth.
  - `Reader.swift`: `getattrlistbulk` folder reader, `privateBytes`, `cloneInfo`, `measure`.
  - `Scanner.swift`: the parallel walk and the adding-up pass (`Scanner.walk` -> `ScanCore`).
  - `Report.swift`: rules with their items, Hugging Face, duplicates, apps and leftovers,
    downloads, `diffTrees`, history, and `Report.run`, which writes `scan.json`.
  - `Cleaner.swift`: the only code that removes anything (`userPathOK`, `resolve`, `clean`, `list`).
  - `Models.swift`: the `scan.json` shapes (`Codable`).
- `app/Sources/*.swift`: the SwiftUI app (macOS 14+).
  - `Engine.swift`: the app's door to the engine (async wrappers) and the `--scan` command line.
  - `AppModel.swift`: all state (`@Observable`): the scan, candidates, the cleanup list (`plan`),
    the clean session, live free space, alerts. `Rows.swift` turns the scan into one `Row` shape
    for every page; `RowList.swift` draws it (selection, context menu, Space, Delete).
  - `Shell.swift` (window, sidebar, toolbar, scanning, What Changed), `Overview.swift` (level
    meter, cards, chart), `MapView.swift` (treemap), `CleanSheet.swift` (cleanup list inspector and
    the review sheet), `MenuBar.swift` (menu bar item, Settings), `App.swift` (entry point, scenes,
    menus, snapshot and self-test modes).
  - Views are marked `@MainActor`: the toolchain here is Swift 5.9, where only `body` is isolated.
  - A plain `VStack` of text above a `List` as a page root rendered a blank window once (What
    Changed). Put page summaries in the list via `RowList(header:)` instead.
- `app/Tests/`: `Harness.swift` (a tiny test harness and the `Fixture` fake home; the Command Line
  Tools ship no XCTest), `Tests.swift`, and `compare.py` for the cross-check.
- `test.sh`: builds and runs the tests, then (if `python3` exists) builds one fixture, scans it
  with both the Swift engine and `scan.py`, and requires the two reports to agree.
  Run it after any engine change. `./test.sh <words>` runs matching tests only.
- `build.sh`: compiles a universal binary with plain `swiftc`, makes the icon, ad-hoc signs, and
  zips to `dist/Headroom.zip`. `--debug` is a quick local build; `--install` moves the app into
  `/Applications` (quitting a running copy first). Rebuild after any edit.
- `Headroom --scan [--root <folder>]` scans from a terminal. `HEADROOM_OUT=<file>` moves
  `scan.json`, `history.json` and the action log into that file's folder (use it for experiments).
  `HEADROOM_TIMING=1` prints how long each part of a scan took.
- `HEADROOM_SNAPSHOT=<dir>` makes the app save a PNG of every page in light and dark and quit (it
  captures its own window, so no Screen Recording permission is needed). `HEADROOM_SELFTEST=<ids>`
  runs file IDs through the real model using the temporary home named by `HEADROOM_FIXTURE_HOME` and a fixture-local Trash.
- `scan.py` and `index.html` are the first version (Python scanner and server, web UI). The app
  does not use or ship them. `scan.py` stays as the reference for the cross-check; `index.html`
  is the read-only snapshot viewer the claude.ai artifact shows, and reads the same `scan.json`.
- Never share or commit `scan.json`: it lists this Mac's folder and file names.
- The app keeps its data in `~/Library/Application Support/Headroom/` (`scan.json`,
  `history.json`, `headroom-actions.log`).

## Safety rules to keep

- The UI only ever hands over item ids. `Cleaner.resolve()` decides what an id means from
  `Rules.table`; a command or path invented by a caller is never run.
- Free-form paths must pass `Cleaner.userPathOK()`: under `~`, two levels deep (three under
  `~/Library`), never `.git`, never through a symlink; or `/Applications/*.app`.
  `AppModel.pickable()` mirrors it for what the UI offers. Change both together, with a test.
- Caches and rebuildable folders (`node_modules`, `target`, ...) are deleted outright; everything
  else goes to the Trash unless the user ticks "Delete immediately".
- Home Trash is explicitly reviewed. Quick Cleanup also respects saved rule exclusions.
- Three safety levels drive the UI: `safe`, `review`, `keep`. A rule `cmd` of `@manual` means
  "not automatable, handle in the owning app".
- Paths in `scan.json` use `~` so a shared snapshot carries no account name.
- Test deletion only inside a `Fixture` (a fake home under the temp folder), never on real data.
  The app’s self-test accepts `file:~/` IDs inside a `HeadroomFixture…` home directly under the system temporary directory.
- Patterns that validate names end in `\z`, not `$`: `$` also matches before a trailing newline.

## Deeper views

- `Report.ruleItems()` lists the independent pieces inside a rule (`Rules.itemLevels` says where
  they live). Items carry `seen` (newest read or write) and `changed` (newest write). macOS moves
  read times forward only occasionally and backups count as reads, so the UI calls it a hint.
- Hugging Face hubs (`Rules.hfHubs`) link repos into a shared blob store. `hfrepo:` ids delete a
  repo plus the blobs only it uses; `hforphans:` deletes blobs nothing links to. Both are worked
  out by the cleaner at delete time, never taken from the caller.
- `Cleaner.list()` returns one folder's live contents (home folder only, read-only, 6 second
  budget). "Look inside" in the UI is built on it.
- Rules in `Rules.permanent` are download caches: removed outright, like other caches.

## History, what changed, uninstalling

- Each scan is compared with the one it replaces: `Report.diffTrees()` reports the deepest
  folders that explain the change, using returnable sizes (`r`) so a fresh clone of something
  already on disk is not growth. The result is `changes` in `scan.json`. `history.json` (numbers
  only) keeps free space per scan plus one reading every 3 hours.
- `app:` ids uninstall an app. Only bundles directly in `/Applications` or `~/Applications` with a
  real `Contents/Info.plist` qualify. The bundle is the default selection. Optional support
  files must be explicitly selected and still matched at execution. `Report.appLeftovers()` finds paths from
  `Rules.leftoverSpots` that carry the app's bundle id (three parts or more) or exact name, pass
  `userPathOK()`, and are reached without a symlink. An id or name used by two installed apps, or
  a vendor folder name, is never matched. A running app is refused. All decided at delete time.

## Scanning: speed and sizes

- `Reader.readDir()` uses `getattrlistbulk` (one call per folder: name, type, mtime, flags, id,
  link count, allocated size, length, clone id, extended flags), with a plain `readdir` fallback.
  Mounted volumes and cloud placeholders are flagged so the walk never enters them.
- The walk is parallel (`WorkQueue`, one `DirNode` per folder), then one pass adds the tree up.
  On this Mac: 6.3M files in about 37 s, the whole scan in about 40 s (the Python one took 180 s).
  More threads do not help: the time is in the kernel.
- Only files with `EF_MAY_SHARE_BLOCKS` are asked for `ATTR_CMNEXT_PRIVATESIZE` and the clone
  copy count, because that call is the slow one (seconds on one large fragmented file). Clones
  with the same clone id, sizes and modified time share an answer (`CloneKey`), which cut 1.6M
  calls to 0.55M with identical totals.
- A clone group's shared bytes are credited to the deepest folder that holds every copy, and
  only if the copies seen equal the copy count macOS reports. The `frees` estimate uses
  private bytes plus shared bytes of groups that appear to live entirely inside it.
- JSON: `bytes` is size on disk, `frees` appears only when smaller. Tree nodes use `s` and `r`.
  `disk.unique` is the scanned total with shared space counted once.
- Never walk a folder without the cloud-placeholder skip: listing a dataless folder makes macOS
  fetch it. A profiling script did this once in `~/Library`. Use `Reader` or check
  `SF_DATALESS_FLAG` first.
- A rescan does not block the window: the earlier scan stays on screen (`model.scanning`), and a
  finished scan keeps the cleanup list.

## Known gaps

- Without Full Disk Access, `~/.Trash`, Mail, Messages and Photos internals are unreadable.
- Local builds are ad-hoc signed by default. Set `HEADROOM_SIGN_IDENTITY` for Developer ID distribution.
  The v0.4.0 GitHub download is Developer ID signed and lacks a notarization ticket.
- Spotlight has no index on this disk, so app last-opened dates are missing.
- Hard links are counted in whichever folder a worker reaches first, so which folder "owns" a
  hard-linked file can differ between scans; totals do not.
- Ollama models are one rule with no per-model list (none installed here to test against).
