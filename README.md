# Headroom

A native macOS disk space analyzer. See what grew, inspect the files behind a large folder,
and review the exact paths or tool commands before cleaning. The Swift scanner runs on your Mac.

[Download Headroom for Mac](https://github.com/nipunbatra/headroom/releases/latest/download/Headroom.zip) ·
[Website and screenshots](https://nipunbatra.github.io/headroom/) ·
[Release notes and checksum](https://github.com/nipunbatra/headroom/releases/latest)

Start in **Overview** to review installers, downloads older than a year, idle builds, or duplicate groups.
Each shortcut opens its filtered list. **Quick Cleanup…** previews eligible caches and build folders.
Settings → Quick Cleanup remembers which rules to include.

- **Clean Up**: known places where space piles up (caches, package managers, simulators, model
  caches, session logs), each marked *Safe to Clear*, *Review First* or *Leave Alone*.
  Open a row to see what is inside it: each model in the Hugging Face cache, each Xcode
  project in DerivedData, each superseded VS Code extension, with its size, age and a hint
  about whether it still looks in use.
- **What Changed**: every scan is compared with the one before it. See which folders grew,
  which shrank, and a chart of free space over time. Clones that share space are not counted as growth.
- **Disk Map**: a drill-down treemap of every folder over 200 MB.
- **Large Files, Projects, Downloads**: large files and duplicate groups with content checks, `node_modules` /
  virtualenvs / build folders in idle projects, old downloads.
- **Large Files filters** combine on-disk size, file kind, and modification date. Rows show the
  estimated recoverable space, which can be smaller when copies share APFS blocks.
- **Applications** keeps settings and support data by default. Choose individual matched support
  paths during uninstall review. Searching for a component also finds it inside its parent app or cleanup rule.
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
| ⇧⌘K | Review Quick Cleanup… |
| ⌘D | Add the selected rows to the cleanup list |
| ⌘⌫ or Delete | Clean the selected rows… |
| ⌘↩ | Review and clean the cleanup list… |
| Space or ⌘Y | Quick Look |
| ⇧⌘R | Show in Finder |
| ⌘↑ | Up one level in the disk map |
| ⌃⌘I | Show or hide the cleanup list |

## Install

Download the universal ZIP from [GitHub Releases](https://github.com/nipunbatra/headroom/releases/latest).
Unzip it, move **Headroom.app** into Applications, and open it on macOS 14 or later.
The v0.4.0 download is signed with Nipun Batra’s Developer ID and distributed without Apple notarization.
If macOS blocks first launch, check the checksum in the release notes. For a copy you trust, Apple
documents the per-app **Open Anyway** option under System Settings → Privacy & Security.
[Apple’s Gatekeeper guide](https://support.apple.com/en-us/102445)

To build from source, install the Xcode Command Line Tools and run:

```bash
git clone https://github.com/nipunbatra/headroom.git
cd headroom
./build.sh --install
```

Local builds use an ad-hoc signature by default. Set `HEADROOM_SIGN_IDENTITY` to a Developer ID
Application identity to sign with hardened runtime and a secure timestamp. Running `./build.sh`
without install leaves both the app and ZIP in `dist/`.

For a fuller picture, give Headroom Full Disk Access in System Settings › Privacy & Security.
Without it the Trash, Mail, Messages and Photos internals cannot be measured.

## How cleaning works

- Caches and rebuildable folders (`node_modules`, Rust `target`, `__pycache__`, tool caches) are
  deleted outright. Where a tool has its own cleaner (`uv cache clean`, `brew cleanup`,
  `npm cache clean`), Headroom runs that instead.
- Ordinary files go to the Trash by default. Home Trash requires a separate review and empties
  only the current account’s home Trash. Maven repositories and notebook checkpoints merit individual review.
- Expand a target in the review sheet to see its path or tool command. Headroom checks selected
  paths again at confirmation. It asks for a fresh review when a target changes or two selections overlap.
- Duplicate review keeps the oldest copy and compares the full contents again before removing another.
  An ordinary scan budgets 4 GB of full-file reads after sampling. Larger groups and older snapshots
  can show sample matches. File ages in Downloads use the last modification date.
- Uninstalling an app starts with just the bundle. Each optional Library path is matched by bundle
  identifier or exact name and checked again at removal. Shared identifiers and vendor directories
  are skipped. Quit a running app before uninstalling.
- Permanent cleanup of a rebuildable folder stops if it contains a nested Git checkout or worktree.
- Headroom refuses anything outside your home folder (apart from apps in `/Applications`),
  top-level folders such as `~/Documents`, anything reached through a symlink, and `.git` folders.
- Every action is written to `~/Library/Application Support/Headroom/headroom-actions.log`.

## Good to know

- Cleanup sizes estimate how much disk space you could recover. APFS lets copies share space (package
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
- `app/Tests/` exercises the scanner, cleaner, SwiftUI model, page filters, and map layout with a
  temporary home and isolated preferences. Run `./test.sh` for the full suite and reference cross-check.
- The [storage and usability audit](docs/storage-audit.md) records the findings, product comparisons,
  verification, and remaining work.
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
fixture_home=$(mktemp -d /tmp/HeadroomFixture.XXXXXXXX)
mkdir "$fixture_home/Downloads"
touch "$fixture_home/Downloads/example"
HEADROOM_FIXTURE_HOME="$fixture_home" HEADROOM_SELFTEST="file:~/Downloads/example" \
  dist/Headroom.app/Contents/MacOS/Headroom
```

The design follows the Mac rules collected in [BAMA](https://github.com/daveebbelaar/bama) as far
as macOS 14 and 15 allow (Liquid Glass needs macOS 26).
