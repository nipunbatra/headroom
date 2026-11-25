# Headroom

A standalone Mac storage analyser and cleaner (in the spirit of CleanMyMac / DaisyDisk / Mole).
It runs without Claude: open `dist/Headroom.app`, it scans, you click Clean.

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
- `app/main.swift`: native window (WKWebView) that starts `scan.py app --stay --port 0`, reads
  the `HEADROOM_URL` line it prints, and loads that page. `app/make_icon.swift` draws the icon.
- `build.sh`: compiles the wrapper with `swiftc` as a universal binary, copies `scan.py` and
  `index.html` into `dist/Headroom.app/Contents/Resources`, makes the icon, ad-hoc signs, and
  zips it to `dist/Headroom.zip` for sharing. `./build.sh --install` then moves the app into
  `/Applications` (quitting a running copy first). Rebuild after any edit.
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

## Known gaps

- APFS clones are counted once per copy, so sizes overstate what deleting returns. Measured on
  this Mac: clearing a 24 GB uv cache returned about 5 GB. Fix: `getattrlist` with
  `ATTR_CMNEXT_PRIVATESIZE` in a native scanner.
- Still needs a Python 3 on the machine (Homebrew or the Xcode Command Line Tools). A Swift
  scanner would remove that.
- Without Full Disk Access, `~/.Trash`, Mail, Messages and Photos internals are unreadable.
- Ad-hoc signed, not notarised: fine on the Mac that built it, Gatekeeper will object elsewhere.
- Spotlight has no index on this disk, so app last-opened dates are missing.
