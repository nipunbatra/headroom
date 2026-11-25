# Headroom

A small Mac app that shows what is filling your disk and clears it when you click.

- **Overview**: free space, a level meter of what fills the disk, and one "Clean safe items" button.
- **Clean up**: known places where space piles up (caches, package managers, simulators, model
  caches, session logs), each marked *safe to clear*, *review first* or *leave alone*.
  Open a rule to see what is inside it: each model in the Hugging Face cache, each Xcode
  project in DerivedData, each superseded VS Code extension, with its size, age and a hint
  about whether it still looks in use.
- **Look inside**: open any folder in place (Downloads, a project, a cache), see what is in it
  live, and clean or reveal single items.
- **Disk map**: a drill-down treemap of every folder over 200 MB.
- **Large files, Projects, Downloads, Applications**: big single files and duplicates,
  `node_modules` / virtualenvs / build folders in idle projects, old downloads, app sizes.

Scanning is read-only. Nothing is removed until you press Clean and confirm.

## Install

Needs macOS 12 or later, the Xcode Command Line Tools (`xcode-select --install`), and Python 3
(the Command Line Tools include one; Homebrew's works too).

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
- Everything else goes to the Trash, so you can put it back, unless you tick "skip the Trash".
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
python3 scan.py              # scan only, writes scan.json (read-only)
python3 scan.py app          # run the UI in your browser at http://127.0.0.1:8765
./build.sh --install         # rebuild the native app after changes
```

`scan.py` is the scanner and the local server, standard library only. `index.html` is the whole
interface. `app/main.swift` is the native window. `CLAUDE.md` describes the design and the safety
rules that the two halves must keep in step. `scan.json` lists your folder and file names, so it
is git-ignored; do not share it.
