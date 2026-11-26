# Headroom

A native Mac app that shows what is filling your disk and clears it when you click.
All Swift: a SwiftUI window, sidebar, toolbar, menus and a menu bar item, with its own scanner.
No Electron, no Python, no account, nothing leaves the Mac.

A full scan of a 1 TB disk with 6.3 million files takes about 40 seconds, and the window stays
usable while it runs.

- **Overview**: free space, a level meter of what fills the disk, and one "Clean Safe Items…" button.
- **Clean Up**: known places where space piles up (caches, package managers, simulators, model
  caches, session logs), each marked *Safe to Clear*, *Review First* or *Leave Alone*.
  Open a row to see what is inside it: each model in the Hugging Face cache, each Xcode
  project in DerivedData, each superseded VS Code extension, with its size, age and a hint
  about whether it still looks in use.
- **What Changed**: every scan is compared with the one before it. See which folders grew,
  which shrank, and a chart of free space over time. Clones that share space are not counted as growth.
- **Disk Map**: a drill-down treemap of every folder over 200 MB.
- **Large Files, Projects, Downloads**: big single files and duplicates, `node_modules` /
  virtualenvs / build folders in idle projects, old downloads.
- **Applications**: uninstall an app together with the support files it left in `~/Library`,
  matched by the app's own bundle identifier. Open a row to see exactly what goes.
- **Look inside**: open any folder in place, see what is in it live, and clean single items.
- **Cleanup list**: tick items on any page; they collect in a side panel and are cleaned together
  after one review sheet that says what will happen to each.
- **Menu bar**: free space at a glance, a warning when it runs low, Clean and Scan one click away.

Scanning is read-only. Nothing is removed until you press Clean and confirm.

### Keyboard

| Keys | Action |
|---|---|
| ⌘R | Scan the disk (⌘. stops it) |
| ⌘1 … ⌘8 | Switch page |
| ⇧⌘K | Clean safe items… |
| ⌘D | Add the selected rows to the cleanup list |
| ⌘⌫ or Delete | Clean the selected rows… |
| ⌘↩ | Review and clean the cleanup list… |
| Space or ⌘Y | Quick Look |
| ⇧⌘R | Show in Finder |
| ⌘↑ | Up one level in the disk map |
| ⌃⌘I | Show or hide the cleanup list |

## Install

Needs macOS 14 or later. Building needs the Xcode Command Line Tools (`xcode-select --install`);
running the built app needs nothing else.

```bash
git clone <this repo> headroom && cd headroom
./build.sh --install
```

That builds a universal app, signs it ad hoc and puts it in `/Applications`. Because you built it
yourself, Gatekeeper does not object. `./build.sh` on its own leaves the app in `dist/` together
with `dist/Headroom.zip`.

If someone sends you the zip instead: unzip, move `Headroom.app` to Applications, open it, then
allow it under System Settings › Privacy & Security › Open Anyway. It is not notarised.

For a fuller picture, give Headroom Full Disk Access in System Settings › Privacy & Security.
Without it the Trash, Mail, Messages and Photos internals cannot be measured.

## How cleaning works

- Caches and rebuildable folders (`node_modules`, Rust `target`, `__pycache__`, tool caches) are
  deleted outright. Where a tool has its own cleaner (`uv cache clean`, `brew cleanup`,
  `npm cache clean`), Headroom runs that instead.
- Everything else goes to the Trash, so you can put it back, unless you tick "Delete immediately".
- Uninstalling an app removes the bundle and the folders in `~/Library` that carry its bundle id or
  exact name. Nothing is matched by pattern, an id or name used by two installed apps is skipped,
  and an app that is running must be quit first.
- Headroom refuses anything outside your home folder (apart from apps in `/Applications`),
  top-level folders such as `~/Documents`, anything reached through a symlink, and `.git` folders.
- Every action is written to `~/Library/Application Support/Headroom/headroom-actions.log`.

## Good to know

- Sizes for cleaning are what deleting actually returns. APFS lets copies share space (package
  managers, Finder duplicates and browser updates all do it), so a 24 GB cache can return 5 GB.
  Headroom asks macOS for each cloned file's private size and how many copies exist, and shows
  the on-disk size next to the returnable one where they differ.
- This is a beta that has run on one Mac. Read the confirmation before you agree to it.

## Working on it

```bash
./test.sh                    # engine tests, then a cross-check against the old Python scanner
./build.sh --debug           # quick build of the app into dist/
./build.sh --install         # optimised universal build, installed into /Applications
dist/Headroom.app/Contents/MacOS/Headroom --scan    # scan from a terminal, no window
```

- `app/Engine/` is the scanner and the cleaner: plain Swift, no UI. `Cleaner.swift` is the only
  code that removes anything, and `Rules.swift` is the table of what may be cleaned and how.
- `app/Sources/` is the SwiftUI app. Everything is built with `swiftc`; there is no Xcode project.
- `app/Tests/` holds 39 tests (267 checks). They build a fake home folder under the temp
  folder and check the path rules, every kind of clean id, clone and hard-link accounting, the
  reports, and what changed between scans. Nothing in your real home is touched.
- `scan.py` and `index.html` are the first version (a Python scanner and a web page). The app no
  longer uses them. `scan.py` is kept so `test.sh` can check that both scanners agree on the same
  fixture; `index.html` still opens a `scan.json` as a read-only snapshot.
- `CLAUDE.md` describes the design and the safety rules. `scan.json` lists your folder and file
  names, so it is git-ignored; do not share it.

Two more checks for anyone changing the app:

```bash
HEADROOM_SNAPSHOT=/tmp/shots dist/Headroom.app/Contents/MacOS/Headroom   # a PNG of every page, light and dark
```

```bash
HEADROOM_SELFTEST="file:~/some/_fixture/file" dist/Headroom.app/Contents/MacOS/Headroom   # cleans fixture ids only
```

The design follows the Mac rules collected in [BAMA](https://github.com/daveebbelaar/bama) as far
as macOS 14 and 15 allow (Liquid Glass needs macOS 26).
