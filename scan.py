#!/usr/bin/env python3
"""Headroom scanner.

Walks the macOS Data volume once, read-only, and writes scan.json for the
Headroom UI (index.html).

    python3 scan.py                 # full scan  -> scan.json
    python3 scan.py --root ~        # only the home folder
    python3 scan.py app             # open Headroom: the UI plus one-click cleanup

Scanning never deletes, moves or modifies anything. Only app mode can remove
files, and only what you confirm in its window (see "app mode" below).

Sizes are allocated bytes (st_blocks), so sparse files such as Docker's disk
image are reported at what they really occupy. Hard links are counted once.
Cloud placeholders (iCloud / Drive files that are not downloaded) are skipped
and never fetched. APFS clones are counted once per copy, so totals can run
slightly above what the disk reports.

Folders are read with getattrlistbulk, which returns a whole folder in one call
along with each file's clone id and a "may share blocks" flag. Files with that
flag are asked for their private size (the bytes that come back at once if the
file is deleted), so every size has a second figure: what deleting returns.
"""
import argparse
import ctypes
import errno
import glob
import hashlib
import hmac
import json
import os
import platform
import plistlib
import re
import secrets
import shutil
import stat
import struct
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

HOME = os.path.expanduser("~")
DATA = "/System/Volumes/Data"
SF_DATALESS = 0x40000000
MB = 1000 * 1000
GB = 1000 * MB

BIG_FILE = 50 * MB          # collected for the large-file and duplicate lists
FOUND_MIN = 20 * MB         # smallest dev leftover worth listing
SIZE_DEPTH = 10             # directory sizes are remembered down to this depth

OPAQUE_SUFFIXES = (".app", ".photoslibrary", ".sparsebundle", ".imovielibrary",
                   ".fcpbundle", ".musiclibrary", ".vmwarevm", ".pvm", ".utm",
                   ".xcarchive")
TOOL_CACHES = {".mypy_cache", ".pytest_cache", ".ruff_cache", ".tox",
               ".ipynb_checkpoints", ".parcel-cache", ".turbo"}
ML_LOGS = {"wandb", "lightning_logs", "mlruns"}
NO_TAG_HOME = {"Library", "Applications", "miniconda3", "anaconda3",
               "miniforge3", "mambaforge", "opt", "go"}

KINDS = {
    "Video": "mp4 mov mkv avi m4v webm wmv mpg mpeg",
    "Images": "jpg jpeg png heic gif tiff tif cr2 nef dng psd webp bmp arw",
    "Audio": "mp3 wav flac m4a aac aiff ogg",
    "Archives": "zip tar gz tgz bz2 xz 7z rar zst whl",
    "Disk images & installers": "dmg iso pkg img raw qcow2 vmdk vdi sparseimage ipsw",
    "ML models & weights": "safetensors ckpt pt pth gguf onnx h5 tflite mlmodel pkl pickle joblib npz npy",
    "Data": "csv parquet json jsonl sqlite db feather arrow hdf5 nc tsv sqlite3",
    "Documents": "pdf doc docx ppt pptx key xls xlsx pages numbers epub",
    "Code & libraries": "py js ts c cpp h java go rs swift ipynb html css so dylib a o pyc map node",
}
EXT_KIND = {e: k for k, exts in KINDS.items() for e in exts.split()}

# (id, group, safety, title, path, why, command or None)
# safety: safe = rebuilt automatically, review = you may want it, keep = informational
RULES = [
    ("trash", "system", "safe", "Trash", "~/.Trash",
     "Files you already threw away. They keep using space until the Trash is emptied.",
     "osascript -e 'tell application \"Finder\" to empty trash'"),
    ("logs", "system", "safe", "App logs", "~/Library/Logs",
     "Diagnostic logs and crash reports. Nothing reads them unless you are debugging.", None),
    ("ios-backups", "system", "review", "iPhone and iPad backups",
     "~/Library/Application Support/MobileSync/Backup",
     "Local device backups. Delete old ones in Finder, or keep them if you have no iCloud backup.", None),
    ("downloads", "system", "review", "Downloads folder", "~/Downloads",
     "Installers and files you fetched once. Sort by size and age in the Downloads view.", "@view:downloads"),

    ("brew", "caches", "safe", "Homebrew downloads", "~/Library/Caches/Homebrew",
     "Installer archives Homebrew keeps after installing.", "brew cleanup -s --prune=all"),
    ("pip", "caches", "safe", "pip cache", "~/Library/Caches/pip",
     "Wheels pip downloaded. Reinstalling fetches them again.", "pip cache purge"),
    ("yarn", "caches", "safe", "Yarn cache", "~/Library/Caches/Yarn",
     "Package tarballs Yarn keeps for offline installs.", "yarn cache clean"),
    ("playwright", "caches", "review", "Playwright browsers", "~/Library/Caches/ms-playwright",
     "Browser builds for Playwright tests. Reinstall with npx playwright install.", None),
    ("uv", "caches", "safe", "uv cache", "~/.cache/uv",
     "Packages uv downloaded and built. Environments keep working, new installs re-download.", "uv cache clean"),
    ("hf", "ml", "review", "Hugging Face cache", "~/.cache/huggingface",
     "Downloaded models and datasets. Anything removed downloads again on next use.", None),
    ("torch", "ml", "review", "PyTorch hub cache", "~/.cache/torch",
     "Pretrained weights fetched by torch.hub and torchvision.", None),
    ("ollama", "ml", "review", "Ollama models", "~/.ollama/models",
     "Local LLM weights. Remove single models with ollama rm <name>.", None),
    ("lmstudio", "ml", "review", "LM Studio models", "~/.lmstudio/models",
     "Local LLM weights downloaded through LM Studio.", None),
    ("lmstudio-rt", "ml", "review", "LM Studio runtimes", "~/.lmstudio/extensions/backends",
     "Inference engines LM Studio downloaded. It keeps old versions; remove the ones you no longer select under Runtimes.",
     "@manual"),
    ("lmstudio2", "ml", "review", "LM Studio models", "~/.cache/lm-studio",
     "Local LLM weights downloaded through LM Studio.", None),
    ("whisper", "ml", "review", "Whisper models", "~/.cache/whisper",
     "Speech-to-text weights. The model you ask for downloads again on next use.", None),
    ("nltk", "ml", "review", "NLTK data", "~/nltk_data",
     "Corpora downloaded by NLTK. Re-download with nltk.download().", None),

    ("npm", "dev", "safe", "npm cache", "~/.npm",
     "Package tarballs npm keeps. Installs re-download what they need.", "npm cache clean --force"),
    ("pnpm", "dev", "safe", "pnpm store", "~/Library/pnpm/store",
     "Shared package store. Prune removes packages no project links to.", "pnpm store prune"),
    ("bun", "dev", "safe", "Bun cache", "~/.bun/install/cache",
     "Packages Bun downloaded.", "bun pm cache rm"),
    ("derived", "dev", "safe", "Xcode DerivedData", "~/Library/Developer/Xcode/DerivedData",
     "Build products and indexes. Xcode rebuilds them the next time you open a project.", None),
    ("devsupport", "dev", "safe", "Xcode device support", "~/Library/Developer/Xcode/iOS DeviceSupport",
     "Debug symbols for every iOS version you have plugged in. Re-created on connect.", None),
    ("previews", "dev", "safe", "Xcode previews", "~/Library/Developer/Xcode/UserData/Previews",
     "SwiftUI preview simulators. Re-created on demand.", None),
    ("archives", "dev", "review", "Xcode archives", "~/Library/Developer/Xcode/Archives",
     "Past app builds with their debug symbols. Keep the ones for shipped versions.", None),
    ("simdevices", "dev", "review", "iOS Simulator devices", "~/Library/Developer/CoreSimulator/Devices",
     "Simulator devices and the apps installed in them. The command removes only ones no runtime supports.",
     "xcrun simctl delete unavailable"),
    ("simcaches", "dev", "safe", "iOS Simulator caches", "~/Library/Developer/CoreSimulator/Caches",
     "dyld caches for simulators. Rebuilt on next boot.", None),
    ("simruntimes", "dev", "review", "iOS Simulator runtimes", "/Library/Developer/CoreSimulator",
     "Downloaded simulator OS images. Remove old versions in Xcode > Settings > Components.", "@manual"),
    ("gradle", "dev", "safe", "Gradle caches", "~/.gradle/caches",
     "Downloaded dependencies and build caches.", None),
    ("maven", "dev", "safe", "Maven repository", "~/.m2/repository",
     "Downloaded Java dependencies.", None),
    ("cargo", "dev", "safe", "Cargo registry", "~/.cargo/registry",
     "Downloaded Rust crates.", None),
    ("rustup", "dev", "review", "Rust toolchains", "~/.rustup/toolchains",
     "Installed compiler versions. Remove old ones with rustup toolchain uninstall.", "@manual"),
    ("gomod", "dev", "safe", "Go module cache", "~/go/pkg/mod",
     "Downloaded Go modules.", "go clean -modcache"),
    ("cocoapods", "dev", "safe", "CocoaPods repos", "~/.cocoapods/repos",
     "Spec repositories. Re-cloned on next pod install.", None),
    ("android-sdk", "dev", "review", "Android SDK", "~/Library/Android/sdk",
     "Platforms, system images and build tools. Prune in Android Studio's SDK Manager.", "@manual"),
    ("android-avd", "dev", "review", "Android emulators", "~/.android/avd",
     "Virtual devices. Delete unused ones in Device Manager.", "@manual"),
    ("nvm", "dev", "review", "Node versions (nvm)", "~/.nvm/versions",
     "Installed Node.js versions and their global packages.", "@manual"),
    ("pyenv", "dev", "review", "Python versions (pyenv)", "~/.pyenv/versions",
     "Installed Python builds.", "@manual"),
    ("uv-python", "dev", "review", "uv Pythons and tools", "~/.local/share/uv",
     "Python builds and tools installed by uv.", "@manual"),
    ("vscode-cache", "dev", "safe", "VS Code caches", "~/Library/Application Support/Code/CachedData",
     "Compiled editor code cache.", None),
    ("vscode-vsix", "dev", "safe", "VS Code extension downloads",
     "~/Library/Application Support/Code/CachedExtensionVSIXs",
     "Installer packages for extensions that are already installed.", None),
    ("vscode-ext", "dev", "review", "VS Code extensions", "~/.vscode/extensions",
     "Installed extensions, including old versions VS Code has not removed yet.", "@manual"),
    ("vscode-sw", "dev", "safe", "VS Code web cache",
     "~/Library/Application Support/Code/Service Worker/CacheStorage",
     "Cached extension and webview assets.", None),
    ("coredevice", "dev", "review", "Xcode device symbols",
     "~/Library/Containers/com.apple.CoreDevice.CoreDeviceService",
     "Debug symbols copied from connected iPhones. Re-created the next time a device connects. Remove it in Finder if you no longer build for devices.",
     "@manual"),
    ("simassets", "dev", "review", "iOS Simulator runtimes (system assets)",
     "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime",
     "Simulator OS images. List them with xcrun simctl runtime list, remove one with xcrun simctl runtime delete <id>.",
     "@manual"),
    ("codex-sessions", "dev", "review", "Codex session logs", "~/.codex/sessions",
     "Transcripts of past Codex sessions, needed only to resume one. The command removes those older than 30 days; the size shown is the whole folder.",
     'find "$HOME/.codex/sessions" -type f -mtime +30 -delete'),
    ("codex-worktrees", "dev", "review", "Codex worktrees", "~/.codex/worktrees",
     "Git worktrees Codex created for tasks. Check each for unmerged work before removing it.", "@manual"),
    ("codex-tasks", "dev", "review", "Codex task workspaces", "~/Documents/Codex",
     "Working folders from Codex tasks, grouped by date. They hold downloaded models and virtual environments; open the map and clear old dates.",
     "@manual"),
    ("claude-sessions", "dev", "review", "Claude Code session logs", "~/.claude/projects",
     "Transcripts of past Claude Code sessions. The command removes transcripts older than 30 days and leaves project memory alone; the size shown is the whole folder.",
     'find "$HOME/.claude/projects" -name "*.jsonl" -mtime +30 -delete'),
    ("webex-updates", "caches", "safe", "Webex update downloads",
     "~/Library/Application Support/Cisco Spark/Webexteams_upgrades_arm",
     "Installer files for Webex updates that are already applied.", None),
    ("brew-cellar", "dev", "keep", "Homebrew packages", "/opt/homebrew/Cellar",
     "Installed formulae. brew cleanup removes outdated versions and brew autoremove drops unused dependencies.",
     "@manual"),
    ("texlive", "dev", "keep", "TeX Live", "/usr/local/texlive",
     "Your LaTeX distribution. Large, but needed to compile papers.", "@manual"),

    ("docker", "containers", "review", "Docker Desktop", "~/Library/Containers/com.docker.docker",
     "Images, containers, volumes and build cache. The command keeps volumes and anything in use.",
     "docker system prune -a -f"),
    ("orbstack", "containers", "review", "OrbStack", "~/Library/Group Containers/HUAQ24HBR6.dev.orbstack",
     "OrbStack's disk image for containers and Linux machines.", "@manual"),
    ("orbstack2", "containers", "review", "OrbStack", "~/.orbstack",
     "OrbStack's data.", "@manual"),
    ("colima", "containers", "review", "Colima", "~/.colima",
     "Colima's virtual machine disk.", "@manual"),
    ("lima", "containers", "review", "Lima", "~/.lima",
     "Lima virtual machines.", "@manual"),

    ("photos", "personal", "keep", "Photos library", "~/Pictures/Photos Library.photoslibrary",
     "Turn on Optimise Mac Storage in Photos > Settings > iCloud to keep originals in iCloud only.", "@manual"),
    ("movies", "personal", "keep", "Movies", "~/Movies",
     "Recordings and video projects. Good candidates for an external drive.", "@manual"),
    ("icloud", "personal", "keep", "iCloud Drive (downloaded)", "~/Library/Mobile Documents",
     "Files kept on this Mac. Right-click > Remove Download keeps them in iCloud only.", "@manual"),
    ("cloud", "personal", "keep", "Cloud storage (downloaded)", "~/Library/CloudStorage",
     "Google Drive, Dropbox or OneDrive files stored offline. Switch folders to online-only.", "@manual"),
    ("whatsapp", "personal", "keep", "WhatsApp media",
     "~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared",
     "Photos and videos from chats. Clear per chat in WhatsApp > Settings > Storage and data > Manage storage.", "@manual"),
    ("messages", "personal", "keep", "Messages attachments", "~/Library/Messages",
     "Photos and videos from conversations. Review in System Settings > General > Storage > Messages.", "@manual"),
    ("mail", "personal", "keep", "Mail", "~/Library/Mail",
     "Downloaded mail and attachments.", "@manual"),
    ("vm", "system", "keep", "Swap and sleep image", "/private/var/vm",
     "Memory that macOS paged to disk. It shrinks after a restart.", "@manual"),
]
CONDA_BASES = ["~/miniconda3", "~/anaconda3", "~/miniforge3", "~/mambaforge",
               "/opt/homebrew/Caskroom/miniconda/base", "/opt/homebrew/Caskroom/miniforge/base",
               "/opt/miniconda3", "/opt/anaconda3"]
for _i, _b in enumerate(CONDA_BASES):
    RULES.append((f"conda-pkgs-{_i}", "dev", "safe", "Conda package cache", _b + "/pkgs",
                  "Downloaded conda packages. Environments keep working without them.",
                  "conda clean --all -y"))
    RULES.append((f"conda-envs-{_i}", "dev", "review", "Conda environments", _b + "/envs",
                  "Every environment you created. Remove unused ones with conda env remove -n <name>.",
                  "@manual"))



def user_temp_rules():
    """Rules for this user's /private/var/folders area (T = temp, C = caches, X = clones)."""
    try:
        t = os.confstr(65537)  # _CS_DARWIN_USER_TEMP_DIR; Python has no name for it
    except (ValueError, OSError):
        t = None
    if not t:
        try:
            t = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True,
                               text=True, timeout=5).stdout.strip()
        except Exception:
            t = ""
    if not t:
        return []
    t = os.path.realpath(t)
    base = os.path.dirname(t.rstrip("/"))
    out = [("tmp-user", "system", "safe", "Temporary files", os.path.join(base, "T"),
            "Scratch files apps left behind. The command removes only entries untouched for three days; the size shown is the whole folder.",
            'find "$(getconf DARWIN_USER_TEMP_DIR)" -mindepth 1 -maxdepth 1 -mtime +3 -exec rm -rf {} +'),
           ("cache-user", "system", "keep", "System-managed app caches", os.path.join(base, "C"),
            "Wallpapers, compiled shaders and similar. macOS rebuilds and trims them itself.", "@manual")]
    try:
        for n in sorted(os.listdir(os.path.join(base, "X"))):
            if n.endswith(".code_sign_clone"):
                app = n[:-len(".code_sign_clone")]
                out.append(("clone-" + n, "caches", "safe", "Browser update clones: " + app,
                            os.path.join(base, "X", n),
                            "Copies of the browser that Chromium makes while updating and often fails to remove. "
                            "Quit the browser first. They are APFS clones, so the space returned can be less than the size shown.",
                            None))
    except OSError:
        pass
    return out


PYCACHE_CMD = 'find "$HOME" -path "$HOME/Library" -prune -o -type d -name __pycache__ -prune -exec rm -rf {} +'

# Folders whose children are each their own cache.
CACHE_CONTAINERS = [("~/Library/Caches", "caches"), ("~/.cache", "caches")]


# ------------------------------------------------------------ reading folders
class _AttrList(ctypes.Structure):
    _fields_ = [("bitmapcount", ctypes.c_ushort), ("reserved", ctypes.c_ushort),
                ("commonattr", ctypes.c_uint32), ("volattr", ctypes.c_uint32), ("dirattr", ctypes.c_uint32),
                ("fileattr", ctypes.c_uint32), ("forkattr", ctypes.c_uint32)]


# common: returned-attrs | name | object type | modified | flags | file id
# folder: mount status.   file: link count | allocated | data length
# extended (in the fork slot): clone id | extended flags
_BULK_AL = _AttrList(5, 0, 0x80000000 | 0x1 | 0x8 | 0x400 | 0x40000 | 0x2000000, 0, 0x4, 0x1 | 0x4 | 0x200, 0x100 | 0x200)
_PRIV_AL = _AttrList(5, 0, 0, 0, 0, 0, 0x8)                 # private size only
_CLONE_AL = _AttrList(5, 0, 0, 0, 0, 0, 0x8 | 0x1000)       # private size | number of clone copies
COPIES = [True]                                             # False once the system refuses the copy count
_HEAD = struct.Struct("<I5IiIIqqIQ")    # length, returned x5, name (offset, length), type, mtime s/ns, flags, id
_FILE = struct.Struct("<IqqQQ")         # links, allocated, length, clone id, extended flags
_MOUNT = struct.Struct("<I")
_BUFSIZE = 1 << 18
_tls = threading.local()
ROOT_DEV = [None]
try:
    _libc = ctypes.CDLL(None, use_errno=True)
    _libc.getattrlistbulk.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint64]
    _libc.getattrlist.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_ulong]
    FAST = [True]
except (OSError, AttributeError):
    FAST = [False]


def _buffers():
    b = getattr(_tls, "bulk", None)
    if b is None:
        b = _tls.bulk = ctypes.create_string_buffer(_BUFSIZE)
        _tls.priv = ctypes.create_string_buffer(16)
    return b, _tls.priv


def read_dir(path):
    """One folder's entries as (name, kind, mtime, id, skip, links, bytes, length, clone id, may share).
    kind is 1 for a file, 2 for a folder; other things are left out. skip marks a folder that must
    not be entered: 1 a mounted volume, 2 a cloud placeholder that would download if opened."""
    if FAST[0]:
        buf = _buffers()[0]
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
        out = []
        try:
            while True:
                count = _libc.getattrlistbulk(fd, ctypes.byref(_BULK_AL), buf, _BUFSIZE, 0x28)
                if count <= 0:
                    if count < 0 and not out:
                        e = ctypes.get_errno()
                        if e in (errno.EINVAL, errno.ENOTSUP):
                            FAST[0] = False            # this file system cannot do it: use the plain reader
                            break
                        raise OSError(e, os.strerror(e))
                    return out
                off = 0
                for _ in range(count):
                    h = _HEAD.unpack_from(buf, off)
                    at = off + 24 + h[6]
                    name = buf[at:at + h[7] - 1].decode("utf-8", "surrogateescape")
                    if h[8] == 1:
                        if h[4]:
                            links, alloc, length, cid, ef = _FILE.unpack_from(buf, off + 64)
                            out.append((name, 1, h[9], h[12], 0, links, alloc, length, cid, ef & 1))
                    elif h[8] == 2:
                        mounted = h[3] and _MOUNT.unpack_from(buf, off + 64)[0] & 1
                        out.append((name, 2, h[9], h[12], 1 if mounted else 2 if h[11] & SF_DATALESS else 0,
                                    0, 0, 0, 0, 0))
                    off += h[0]
        finally:
            os.close(fd)
    out = []
    with os.scandir(path) as it:
        for e in it:
            try:
                st = e.stat(follow_symlinks=False)
            except OSError:
                continue
            if stat.S_ISREG(st.st_mode):
                out.append((e.name, 1, int(st.st_mtime), st.st_ino, 0, st.st_nlink, st.st_blocks * 512,
                            st.st_size, 0, 0))
            elif stat.S_ISDIR(st.st_mode):
                skip = (1 if ROOT_DEV[0] is not None and st.st_dev != ROOT_DEV[0]
                        else 2 if getattr(st, "st_flags", 0) & SF_DATALESS else 0)
                out.append((e.name, 2, int(st.st_mtime), st.st_ino, skip, 0, 0, 0, 0, 0))
    return out


def private_bytes(path):
    """Bytes that come back at once if this file is deleted: 0 for a pure clone. None if unknown."""
    if not FAST[0]:
        return None
    buf = _buffers()[1]
    if _libc.getattrlist(os.fsencode(path), ctypes.byref(_PRIV_AL), buf, 16, 0x21) != 0:
        return None
    return struct.unpack_from("<Iq", buf)[1]


def clone_info(path):
    """(bytes deleting this file returns, how many clone copies exist or None if the system cannot say)."""
    if not FAST[0]:
        return None, None
    buf = _buffers()[1]
    if COPIES[0]:
        if _libc.getattrlist(os.fsencode(path), ctypes.byref(_CLONE_AL), buf, 16, 0x21) == 0:
            length, private, copies = struct.unpack_from("<IqI", buf)
            return private, copies
        if ctypes.get_errno() == errno.EINVAL:
            COPIES[0] = False                # older macOS: no copy count
    return private_bytes(path), None


def measure(path, deadline=None):
    """(bytes, bytes deleting it returns, files, newest change, cut short) for one folder tree.
    Clones whose every copy sits inside the tree count once toward what deleting returns."""
    total = priv = files = newest = 0
    groups = {}
    stack = [path]
    partial = False
    while stack:
        if deadline and time.time() > deadline:
            partial = True
            break
        d = stack.pop()
        try:
            entries = read_dir(d)
        except OSError:
            continue
        for fn, kind, mtime, ino, skip, links, sz, length, cid, share in entries:
            if kind == 1:
                pv = sz
                if share and sz:
                    p, copies = clone_info(d + "/" + fn)
                    if p is not None and p < sz:
                        pv = p
                        g = groups.get(cid)
                        if g is None:
                            groups[cid] = [sz - p, 1, copies]
                        else:
                            g[0] = max(g[0], sz - p)
                            g[1] += 1
                total += sz
                priv += pv
                files += 1
                if mtime > newest:
                    newest = mtime
            elif not skip:
                stack.append(d + "/" + fn)
    # shared space comes back only when every copy of the clone is inside this tree
    priv += sum(shared for shared, n, copies in groups.values() if n > 1 and (copies is None or n >= copies))
    return total, min(total, priv), files, newest, partial


def expand(p):
    return os.path.expanduser(p)


def disp(p):
    """Logical path with the home folder shortened to ~."""
    if p == HOME:
        return "~"
    if p.startswith(HOME + "/"):
        return "~" + p[len(HOME):]
    return p


def scan(root, min_node, max_depth):
    ROOT_DEV[0] = os.lstat(root).st_dev
    strip = len(root) if root != "/" and root == DATA else 0
    home_real = (root + HOME) if strip else HOME

    sizes, privs, groups, ext, big, found, denied = {}, {}, {}, {}, [], [], []
    seen_ino = set()
    tag_totals = {}
    stats = {"files": 0, "dirs": 0, "dataless": 0}
    last = [time.time()]

    def classify(name, parent, path):
        if name == "node_modules":
            return "node_modules"
        if name == ".git":
            return "git"
        if name == "__pycache__":
            return "pycache"
        if name in (".venv", "venv", "env", ".env") and os.path.exists(path + "/pyvenv.cfg"):
            return "venv"
        if name in TOOL_CACHES:
            return "toolcache"
        if name in ML_LOGS:
            return "ml-logs"
        if name == "target" and os.path.exists(parent + "/Cargo.toml"):
            return "rust-target"
        if name in (".next", ".nuxt"):
            return "web-build"
        if name == "Pods" and os.path.exists(parent + "/Podfile"):
            return "pods"
        return None

    def walk(path, name, depth, opaque, visible, tagok):
        total = priv = nfiles = 0
        kids = None if opaque else []
        lpath = path[strip:] or "/"
        try:
            entries = read_dir(path)
        except OSError:
            denied.append(lpath)
            return 0, 0, None, 0
        subdirs = []
        for fn, kind, mtime, ino, skip, links, sz, length, cid, share in entries:
            if kind == 1:
                if links > 1:
                    if ino in seen_ino:
                        continue
                    seen_ino.add(ino)
                pv = sz
                if share and sz:
                    p, copies = clone_info(path + "/" + fn)
                    if p is not None and p < sz:
                        pv = p
                        g = groups.get(cid)            # clone group: [deepest folder holding every copy seen, shared bytes, copies seen, copies that exist]
                        if g is None:
                            groups[cid] = [lpath, sz - p, 1, copies]
                        else:
                            top = g[0]
                            while top != "/" and not (lpath == top or lpath.startswith(top + "/")):
                                top = os.path.dirname(top)
                            g[0] = top
                            if sz - p > g[1]:
                                g[1] = sz - p
                            g[2] += 1
                total += sz
                priv += pv
                nfiles += 1
                i = fn.rfind(".")
                x = fn[i + 1:].lower() if 0 < i and len(fn) - i <= 12 else ""
                t = ext.get(x)
                if t is None:
                    ext[x] = [sz, 1]
                else:
                    t[0] += sz
                    t[1] += 1
                if sz >= BIG_FILE:
                    big.append((sz, (lpath if lpath != "/" else "") + "/" + fn, mtime, length, ino, opaque, x, pv))
                    if kids is not None and sz >= min_node and depth < max_depth:
                        leaf = {"n": fn, "s": sz, "k": "f"}
                        if pv < sz:
                            leaf["r"] = pv
                        kids.append(leaf)
            elif skip:
                if skip == 2:
                    stats["dataless"] += 1
            else:
                subdirs.append((fn, path + "/" + fn))
        stats["files"] += nfiles
        stats["dirs"] += 1
        if time.time() - last[0] > 5:
            last[0] = time.time()
            print(f"  {stats['files']:>10,} files  {lpath[:90]}", file=sys.stderr, flush=True)

        at_home = path == home_real
        tag = None
        for dn, dp in subdirs:
            c_opaque, c_tagok, tag = opaque, tagok, None
            if at_home:
                c_tagok = not (dn.startswith(".") or dn in NO_TAG_HOME)
            if not opaque:
                if c_tagok:
                    tag = classify(dn, path, dp)
                if tag or dn.endswith(OPAQUE_SUFFIXES):
                    c_opaque = True
            s, n, node, pr = walk(dp, dn, depth + 1, c_opaque, not opaque, c_tagok)
            total += s
            priv += pr
            nfiles += n
            if tag:
                tt = tag_totals.setdefault(tag, [0, 0])
                tt[0] += s
                tt[1] += 1
                if s >= FOUND_MIN:
                    found.append((tag, dp[strip:], s, n, pr))
                if node is not None:
                    node["t"] = tag
            if node is not None and kids is not None:
                kids.append(node)

        if depth <= SIZE_DEPTH and total >= MB:
            sizes[lpath] = total
            if priv < total:
                privs[lpath] = priv
        if visible and total >= min_node and depth <= max_depth:
            node = {"n": name, "s": total, "f": nfiles}
            if priv < total:
                node["r"] = priv
            if kids:
                kids.sort(key=lambda k: -k["s"])
                node["c"] = kids
            if opaque:
                node["o"] = 1
            return total, nfiles, node, priv
        return total, nfiles, None, priv

    sys.setrecursionlimit(20000)
    total, nfiles, tree, priv = walk(root, "Macintosh HD", 0, False, True, False)
    if tree is None:
        tree = {"n": "Macintosh HD", "s": total, "f": nfiles}

    # A clone group whose every copy sits under a folder is freed when that folder goes:
    # credit its shared bytes to the deepest such folder and to everything above it.
    extra = {}
    for top, shared, seen, copies in groups.values():
        if seen < 2 or (copies is not None and seen < copies):
            continue                                   # a copy lives somewhere the scan did not reach
        while True:
            extra[top] = extra.get(top, 0) + shared
            if top == "/" or not top:
                break
            top = os.path.dirname(top)

    def settle(node, lpath):
        if "c" in node or "r" in node:
            r = node.get("r", node["s"]) + (extra.get(lpath, 0) if node.get("k") != "f" else 0)
            if r < node["s"]:
                node["r"] = r
            else:
                node.pop("r", None)
        for c in node.get("c", ()):
            settle(c, (lpath if lpath != "/" else "") + "/" + c["n"])
    settle(tree, root[strip:] or "/")

    def frees(lpath):
        """What deleting this folder returns, or None when the scan did not keep its size."""
        if lpath not in sizes:
            return None
        return min(sizes[lpath], privs.get(lpath, sizes[lpath]) + extra.get(lpath, 0))

    unique = min(total, priv + extra.get(root[strip:] or "/", 0))
    return dict(total=total, unique=unique, tree=tree, sizes=sizes, ext=ext, big=big, found=found,
                denied=denied, stats=stats, tag_totals=tag_totals, frees=frees, extra=extra)


def project_mtime(parent, skip):
    """Latest change among a project's own top-level entries."""
    latest = 0
    try:
        with os.scandir(parent) as it:
            for e in it:
                if e.name == skip or e.name == ".DS_Store":
                    continue
                try:
                    latest = max(latest, e.stat(follow_symlinks=False).st_mtime)
                except OSError:
                    pass
        for extra in (".git/index", ".git/HEAD"):
            try:
                latest = max(latest, os.stat(os.path.join(parent, extra)).st_mtime)
            except OSError:
                pass
    except OSError:
        pass
    return int(latest)


# ------------------------------------------------------------ what is inside a rule
PERMANENT = {"hf", "whisper", "torch"}      # download caches: removed outright, like any cache
HF_HUBS = ["~/.cache/huggingface/hub", "~/.cache/whisper"]
HF_REPO = re.compile(r"(models|datasets|spaces)--[A-Za-z0-9._\-]+")
HF_KIND = {"models": "Model", "datasets": "Dataset", "spaces": "Space"}
# rule id -> where its independent pieces live ("*" is one folder level)
ITEM_LEVELS = {
    "hf": ["datasets/*", "xet", "modules", "trackio"],
    "whisper": ["*"],
    "lmstudio": ["*/*"],
    "lmstudio-rt": ["vendor/*", "*"],
    "lmstudio2": ["models/*/*"],
    "torch": ["hub/checkpoints/*", "hub/*"],
    "nltk": ["*/*"],
    "derived": ["*"], "devsupport": ["*"], "archives": ["*/*"], "simdevices": ["*"], "ios-backups": ["*"],
    "codex-tasks": ["*"], "codex-sessions": ["*/*"], "codex-worktrees": ["*"], "claude-sessions": ["*"],
    "conda-envs": ["*"], "pyenv": ["*"], "nvm": ["node/*"], "rustup": ["*"], "vscode-ext": ["*"],
    "playwright": ["*"], "android-avd": ["*"],
}
ITEM_MIN = 10 * MB
ITEM_KEEP = 80


def last_seen(path, cap=3000):
    """(newest read-or-write, newest write) among a folder's files, looking at up to `cap` of them.
    macOS moves read times forward only now and then, so the first value is a lower bound on
    last use: the thing was in use at least that recently."""
    seen = changed = 0
    try:
        st = os.lstat(path)
    except OSError:
        return 0, 0
    if not stat.S_ISDIR(st.st_mode):
        return int(max(st.st_atime, st.st_mtime)), int(st.st_mtime)
    stack, n = [path], 0
    while stack and n < cap:
        try:
            with os.scandir(stack.pop()) as it:
                for e in it:
                    try:
                        st = e.stat(follow_symlinks=False)
                    except OSError:
                        continue
                    if stat.S_ISDIR(st.st_mode):
                        stack.append(e.path)
                    elif stat.S_ISREG(st.st_mode):
                        n += 1
                        seen = max(seen, st.st_atime, st.st_mtime)
                        changed = max(changed, st.st_mtime)
        except OSError:
            continue
    return int(seen), int(changed)


def folder_bytes(path):
    total = 0
    for root, dirs, files in os.walk(path):
        for f in files:
            try:
                st = os.lstat(os.path.join(root, f))
                if stat.S_ISREG(st.st_mode):
                    total += st.st_blocks * 512
            except OSError:
                pass
    return total


def hf_links(hub):
    """Hugging Face hub layout: each repo folder links into a shared, content-addressed blob
    store at <hub>/blobs. Returns ({repo folder: set of shared blobs it links to}, store path)."""
    shared = os.path.join(hub, "blobs")
    out = {}
    try:
        names = os.listdir(hub)
    except OSError:
        return out, shared
    for n in names:
        repo = os.path.join(hub, n)
        if not HF_REPO.fullmatch(n) or os.path.islink(repo) or not os.path.isdir(repo):
            continue
        targets = set()
        for sub in ("blobs", "snapshots"):
            for root, dirs, files in os.walk(os.path.join(repo, sub)):
                for f in files:
                    p = os.path.join(root, f)
                    if os.path.islink(p):
                        t = os.path.realpath(p)
                        if t.startswith(shared + os.sep):
                            targets.add(t)
        out[repo] = targets
    return out, shared


def hf_orphans(hub, links=None, shared=None):
    """Files in the shared blob store that no repo links to any more."""
    if links is None:
        links, shared = hf_links(hub)
    used = set().union(*links.values()) if links else set()
    out = []
    for root, dirs, files in os.walk(shared):
        for f in files:
            p = os.path.join(root, f)
            if p not in used and not os.path.islink(p):
                out.append(p)
    return out


def with_frees(obj, frees):
    """Record what deleting returns, when the scan knows it and it is less than the size on disk."""
    if frees is not None and frees < obj["bytes"]:
        obj["frees"] = frees
    return obj


def hf_items(hub, sizes, frees=None):
    links, shared = hf_links(hub)
    owners = {}
    for ts in links.values():
        for t in ts:
            owners[t] = owners.get(t, 0) + 1
    items = []
    for repo, ts in links.items():
        own = sizes.get(repo, 0) if sizes is not None else folder_bytes(repo)
        own_back = frees(repo) if frees else None
        back = own if own_back is None else own_back
        seen, changed = last_seen(repo)
        mine = common = 0
        for t in ts:
            try:
                st = os.stat(t)
            except OSError:
                continue
            b = st.st_blocks * 512
            if owners[t] == 1:
                mine += b
                pb = private_bytes(t)
                back += b if pb is None else pb
            else:
                common += b
            seen = max(seen, int(st.st_atime), int(st.st_mtime))
            changed = max(changed, int(st.st_mtime))
        kind, _, rest = os.path.basename(repo).partition("--")
        item = {"id": "hfrepo:" + disp(repo), "name": rest.replace("--", "/"), "kind": HF_KIND[kind],
                "path": disp(repo), "bytes": own + mine, "seen": seen, "changed": changed}
        with_frees(item, back)
        if common >= 50 * MB:
            item["note"] = f"Another {common / GB:.1f} GB is shared with other entries and stays until they go too."
        items.append(item)
    orphans = hf_orphans(hub, links, shared)
    b = back = 0
    for p in orphans:
        try:
            one = os.lstat(p).st_blocks * 512
        except OSError:
            continue
        pb = private_bytes(p)
        b += one
        back += one if pb is None else pb
    if b >= ITEM_MIN:
        items.append(with_frees({"id": "hforphans:" + disp(hub), "name": "Leftover blobs", "kind": "Leftover",
                                 "path": disp(shared), "bytes": b, "seen": 0, "changed": 0, "flag": "leftover",
                                 "note": f"{len(orphans):,} stored files that no model or dataset links to any more."},
                                back))
    return items


def decorate(key, item, p, rule_path):
    """Rule-specific names and hints for one item."""
    rel = os.path.relpath(p, rule_path)
    name = rel
    for prefix in ("models/", "hub/checkpoints/", "hub/", "node/"):
        if rel.startswith(prefix):
            name = rel[len(prefix):]
            break
    if key == "hf":
        if rel.startswith("datasets/"):
            name, item["kind"] = rel[9:].replace("___", "/"), "Prepared dataset"
        elif rel == "xet":
            name, item["kind"], item["flag"] = "Xet transfer cache", "Cache", "leftover"
            item["note"] = "Download chunks kept to speed up later transfers."
    elif key == "claude-sessions":
        enc = HOME.replace("/", "-")
        name = (rel[len(enc):].lstrip("-") or "home folder") if rel.startswith(enc) else rel
    elif key == "simdevices":
        try:
            with open(os.path.join(p, "device.plist"), "rb") as f:
                d = plistlib.load(f)
            runtime = d.get("runtime", "").rsplit(".", 1)[-1].replace("-", " ", 1).replace("-", ".")
            name = f"{d.get('name', rel)} ({runtime})" if runtime else d.get("name", rel)
        except Exception:  # noqa: BLE001 - keep the folder name
            pass
    item["name"] = name


def flag_old_versions(items, rule_path):
    """VS Code keeps superseded extension versions around for a while; point them out."""
    obsolete = {}
    try:
        with open(os.path.join(rule_path, ".obsolete")) as f:
            obsolete = json.load(f)
    except (OSError, ValueError):
        pass
    newest = {}
    parsed = {}
    for it in items:
        m = re.match(r"^(.+?)-(\d+(?:\.\d+)+)(?:-.+)?$", it["name"])
        if not m:
            continue
        ver = tuple(int(x) for x in m.group(2).split("."))
        parsed[it["id"]] = (m.group(1), ver, m.group(2))
        if ver > newest.get(m.group(1), ((), ""))[0]:
            newest[m.group(1)] = (ver, m.group(2))
    for it in items:
        ext = parsed.get(it["id"])
        if it["name"] in obsolete or (ext and ext[1] < newest[ext[0]][0]):
            it["flag"] = "leftover"
            it["note"] = (f"Superseded: version {newest[ext[0]][1]} is installed." if ext and ext[1] < newest[ext[0]][0]
                          else "VS Code has marked this version for removal.")


def rule_items(rid, path, sizes, frees=None):
    """The independent pieces inside a rule's folder, largest first, each with its size and age.
    `sizes` is the scan's folder-size table; pass None to measure folders directly."""
    key = re.sub(r"-\d+$", "", rid)
    hubs = {expand(h) for h in HF_HUBS}
    items = []
    rest_n = rest_b = 0
    for hub in (path, os.path.join(path, "hub")):
        if hub in hubs and os.path.isdir(hub):
            for it in hf_items(hub, sizes, frees):
                if it["bytes"] >= ITEM_MIN:
                    items.append(it)
                else:
                    rest_n += 1
                    rest_b += it["bytes"]
    found = []
    for pat in ITEM_LEVELS.get(key, []):
        found += glob.glob(os.path.join(glob.escape(path), pat))
    found = sorted(set(found))
    for p in found:
        name = os.path.basename(p)
        if os.path.islink(p) or name.startswith(".") or name == "CACHEDIR.TAG":
            continue
        if os.path.dirname(p) in hubs and (HF_REPO.fullmatch(name) or name == "blobs"):
            continue                                    # handled by hf_items
        if any(q.startswith(p + os.sep) for q in found):
            continue                                    # a parent of other items, not an item itself
        if os.path.isdir(p):
            b = sizes.get(p, 0) if sizes is not None else folder_bytes(p)
            back = frees(p) if frees else None
        else:
            try:
                b = os.lstat(p).st_blocks * 512
            except OSError:
                continue
            back = private_bytes(p)
        if b < ITEM_MIN:
            rest_n += 1
            rest_b += b
            continue
        seen, changed = last_seen(p)
        item = {"id": "file:" + disp(p), "path": disp(p), "bytes": b, "seen": seen, "changed": changed}
        if os.path.isdir(p):
            item["dir"] = True
        with_frees(item, back)
        decorate(key, item, p, path)
        items.append(item)
    if key == "vscode-ext":
        flag_old_versions(items, path)
    items.sort(key=lambda i: -i.get("frees", i["bytes"]))
    for it in items[ITEM_KEEP:]:
        rest_n += 1
        rest_b += it["bytes"]
    return items[:ITEM_KEEP], ({"count": rest_n, "bytes": rest_b} if rest_n else None)


def build_rules(sizes, tag_totals=None, frees=None):
    out = []
    pyc = (tag_totals or {}).get("pycache")
    if pyc and pyc[0] >= 50 * MB:
        out.append({"id": "pycache", "group": "dev", "safety": "safe",
                    "title": "Python bytecode (__pycache__)", "paths": [], "bytes": pyc[0],
                    "why": f"{pyc[1]:,} folders of compiled .pyc files. Python rewrites them the next time the code runs.",
                    "cmd": PYCACHE_CMD})
    specific = set()
    for rid, group, safety, title, path, why, cmd in RULES + user_temp_rules():
        p = expand(path)
        specific.add(p)
        b = sizes.get(p, 0)
        if b < 50 * MB:
            continue
        rule = {"id": rid, "group": group, "safety": safety, "title": title,
                "paths": [disp(p)], "bytes": b, "why": why, "cmd": cmd}
        if rid in PERMANENT:
            rule["perm"] = True
        with_frees(rule, frees(p) if frees else None)
        try:
            items, rest = rule_items(rid, p, sizes, frees)
        except OSError:
            items, rest = [], None
        if items:
            rule["items"] = items
            if rest:
                rule["itemsRest"] = rest
        out.append(rule)
    for container, group in CACHE_CONTAINERS:
        c = expand(container)
        rest, rest_bytes, rest_back = [], 0, 0
        try:
            names = sorted(os.listdir(c))
        except OSError:
            continue
        for n in names:
            p = os.path.join(c, n)
            if p in specific or not os.path.isdir(p) or os.path.islink(p):
                continue
            b = sizes.get(p, 0)
            back = frees(p) if frees else None
            if b >= 150 * MB:
                out.append(with_frees({"id": "cache:" + disp(p), "group": group, "safety": "safe",
                                       "title": "Cache: " + n, "paths": [disp(p)], "bytes": b,
                                       "why": "An app's cache folder. The app rebuilds it when it next runs; quit the app first.",
                                       "cmd": None}, back))
            elif b > 0:
                rest.append(disp(p))
                rest_bytes += b
                rest_back += b if back is None else back
        if rest_bytes >= 20 * MB:
            out.append(with_frees({"id": "cache-rest:" + container, "group": group, "safety": "safe",
                                   "title": f"{len(rest)} smaller caches in {container}", "paths": rest,
                                   "bytes": rest_bytes,
                                   "why": "Small per-app cache folders. Rebuilt on demand.", "cmd": None}, rest_back))
    out.sort(key=lambda r: -r.get("frees", r["bytes"]))
    return out


def find_dupes(big, strip_root):
    by_size = {}
    own = HOME + "/"
    for sz, path, mtime, apparent, ino, opaque, x, pv in big:
        # only the user's own folders: caches, app data and package stores hold
        # deliberate copies (and APFS clones) that are not worth flagging
        rel = path[len(own):] if path.startswith(own) else ""
        if opaque or sz == 0 or not rel or rel.startswith(".") or rel.split("/", 1)[0] in NO_TAG_HOME:
            continue
        by_size.setdefault(apparent, []).append((path, sz, ino, mtime))
    groups = []
    for apparent, files in by_size.items():
        if len(files) < 2:
            continue
        by_hash = {}
        for path, sz, ino, mtime in files:
            try:
                h = hashlib.sha1()
                with open(strip_root + path, "rb") as f:
                    h.update(f.read(2 * MB))
                    if apparent > 4 * MB:
                        f.seek(apparent // 2)
                        h.update(f.read(MB))
                        f.seek(-2 * MB, os.SEEK_END)
                        h.update(f.read(2 * MB))
                by_hash.setdefault(h.hexdigest(), {})[ino] = (path, sz, mtime)
            except OSError:
                continue
        for same in by_hash.values():
            if len(same) > 1:
                items = sorted(same.values(), key=lambda t: t[2])
                groups.append({"bytes": items[0][1],
                               "files": [{"path": disp(p), "mtime": int(m)} for p, _, m in items]})
    groups.sort(key=lambda g: -g["bytes"] * (len(g["files"]) - 1))
    return groups[:60]


def app_list(sizes, frees=None):
    apps = []
    for base in ("/Applications", "/Applications/Utilities", expand("~/Applications")):
        try:
            names = os.listdir(base)
        except OSError:
            continue
        for n in names:
            if n.endswith(".app"):
                p = os.path.join(base, n)
                apps.append(with_frees({"name": n[:-4], "path": disp(p), "bytes": sizes.get(p, 0), "_p": p},
                                       frees(p) if frees else None))

    def last_used(a):
        try:
            r = subprocess.run(["mdls", "-raw", "-name", "kMDItemLastUsedDate", a["_p"]],
                               capture_output=True, text=True, timeout=10).stdout.strip()
            if r and r != "(null)":
                a["lastUsed"] = int(time.mktime(time.strptime(r[:19], "%Y-%m-%d %H:%M:%S"))) - time.timezone
        except Exception:
            pass
    with ThreadPoolExecutor(8) as ex:
        list(ex.map(last_used, apps))
    for a in apps:
        del a["_p"]
    apps.sort(key=lambda a: -a["bytes"])
    return apps


def downloads(sizes, frees=None):
    d = expand("~/Downloads")
    out = []
    try:
        with os.scandir(d) as it:
            for e in it:
                if e.name.startswith("."):
                    continue
                try:
                    st = e.stat(follow_symlinks=False)
                except OSError:
                    continue
                isdir = stat.S_ISDIR(st.st_mode)
                b = sizes.get(e.path, 0) if isdir else st.st_blocks * 512
                back = (frees(e.path) if frees else None) if isdir else private_bytes(e.path)
                if b >= 5 * MB:
                    out.append(with_frees({"name": e.name, "bytes": b, "mtime": int(st.st_mtime), "dir": isdir}, back))
    except OSError:
        return None
    out.sort(key=lambda x: -x["bytes"])
    return out[:150]


def disk_info():
    info = {}
    target = DATA if os.path.isdir(DATA) else "/"
    sv = os.statvfs(target)
    info["total"] = sv.f_blocks * sv.f_frsize
    info["free"] = sv.f_bavail * sv.f_frsize
    try:
        line = subprocess.run(["df", "-k", target], capture_output=True, text=True).stdout.splitlines()[1].split()
        info["dataUsed"] = int(line[2]) * 1024
    except Exception:
        info["dataUsed"] = info["total"] - info["free"]
    try:
        snaps = subprocess.run(["tmutil", "listlocalsnapshots", "/"], capture_output=True, text=True,
                               timeout=15).stdout
        info["snapshots"] = sum(1 for l in snaps.splitlines() if "com.apple" in l)
    except Exception:
        info["snapshots"] = 0
    return info


def mark_home(tree):
    """Rename the home node to "~" so scan.json carries no account name."""
    node = tree
    for part in [p for p in HOME.split("/") if p]:
        node = next((c for c in node.get("c", []) if c["n"] == part), None)
        if node is None:
            return
    node["n"] = "~"
    node["h"] = 1


def run_scan(args):
    root = os.path.abspath(expand(args.root)) if args.root else (DATA if os.path.isdir(DATA) else "/")
    t0 = time.time()
    print(f"Scanning {root} (read-only)...", file=sys.stderr)
    r = scan(root, args.min_mb * MB, args.depth)
    sizes = r["sizes"]
    strip_root = root if root == DATA else ""
    print("Walk done, analysing...", file=sys.stderr)

    kinds = {}
    for x, (b, n) in r["ext"].items():
        k = kinds.setdefault(EXT_KIND.get(x, "Everything else"), [0, 0])
        k[0] += b
        k[1] += n
    top_ext = sorted(((x or "(none)", b, n) for x, (b, n) in r["ext"].items()), key=lambda t: -t[1])[:40]

    found = []
    frees, extra = r["frees"], r["extra"]
    for tag, path, b, n, pr in r["found"]:
        if tag == "pycache":
            continue
        parent = os.path.dirname(path)
        found.append(with_frees({"tag": tag, "path": disp(path), "bytes": b, "files": n,
                                 "projectMtime": project_mtime(strip_root + parent, os.path.basename(path))},
                                pr + extra.get(path, 0)))
    found.sort(key=lambda f: -f.get("frees", f["bytes"]))

    big = sorted(r["big"], key=lambda t: -t[0])
    big_files = [with_frees({"path": disp(p), "bytes": sz, "mtime": int(mt),
                             "kind": EXT_KIND.get(x, "Everything else")}, pv)
                 for sz, p, mt, ap, ino, opq, x, pv in big if not opq][:400]

    if root == DATA or root == "/":
        mark_home(r["tree"])
    else:
        r["tree"]["n"] = disp(root)
    disk = disk_info()
    disk["scanned"] = r["total"]
    disk["unique"] = r["unique"]        # the same files with clone-shared space counted once
    out = {
        "version": 1,
        "scannedAt": int(time.time()),
        "seconds": 0,
        "os": "macOS " + platform.mac_ver()[0],
        "root": disp(root[len(strip_root):] or "/"),
        "disk": disk,
        "stats": r["stats"],
        "tree": r["tree"],
        "kinds": sorted(({"kind": k, "bytes": b, "files": n} for k, (b, n) in kinds.items()),
                        key=lambda k: -k["bytes"]),
        "exts": [{"ext": x, "bytes": b, "files": n} for x, b, n in top_ext],
        "rules": build_rules(sizes, r["tag_totals"], frees),
        "found": found[:600],
        "tagTotals": {k: {"bytes": v[0], "count": v[1]} for k, v in r["tag_totals"].items()},
        "bigFiles": big_files,
        "dupes": find_dupes(r["big"], strip_root),
        "downloads": downloads(sizes, frees),
        "apps": app_list(sizes, frees),
        "denied": sorted((disp(p) for p in r["denied"]), key=lambda p: (not p.startswith("~"), p))[:200],
        "deniedCount": len(r["denied"]),
    }
    out["seconds"] = round(time.time() - t0, 1)
    tmp = args.out + ".tmp"
    with open(tmp, "w") as f:
        json.dump(out, f, separators=(",", ":"), ensure_ascii=False)
    os.replace(tmp, args.out)
    print(f"Wrote {args.out}: {r['stats']['files']:,} files, {r['total'] / GB:.1f} GB ({r['unique'] / GB:.1f} GB unique) "
          f"in {out['seconds']}s", file=sys.stderr)


# ---------------------------------------------------------------- app mode
# A server on 127.0.0.1 that shows the UI and carries out the cleanup you
# confirm there. Rules it holds itself to:
#   * The browser only ever sends item ids. What an id means (which command,
#     which folder) is decided here, from the tables in this file. A command
#     string or path invented by the page is never executed.
#   * Free-form paths ("file:" ids) must pass user_path_ok(): inside the home
#     folder, at least two levels deep (three under ~/Library), never a .git
#     folder, never reached through a symlink; or an app in /Applications.
#   * Caches and rebuildable folders are deleted outright. Everything else is
#     moved to the Trash unless the "delete outright" box is ticked.
#   * Every request needs the per-launch token and a 127.0.0.1 Host header, so
#     no web page can drive it. Every action is appended to the action log.

HERE = os.path.dirname(os.path.abspath(__file__))
REBUILDABLE = {"node_modules", "target", ".next", ".nuxt", "Pods", "__pycache__"} | TOOL_CACHES
EXTRA_PATH = ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "~/.cargo/bin", "~/.bun/bin", "~/go/bin"]
IDLE_EXIT = 600            # seconds without a request before the server quits
STATE = {"last": time.time(), "busy": 0}
SCAN = {"running": False, "progress": "", "error": ""}
CLEAN_LOCK = threading.Lock()


class Refused(Exception):
    pass


def free_bytes():
    sv = os.statvfs(DATA if os.path.isdir(DATA) else "/")
    return sv.f_bavail * sv.f_frsize


def user_path_ok(p):
    """Mirror of pickable() in index.html, plus symlink checks."""
    if not p.startswith("/") or p != os.path.normpath(p):
        return False
    if "/.git/" in p + "/":
        return False
    if re.fullmatch(r"/Applications/[^/]+\.app", p):
        return True
    if not p.startswith(HOME + "/"):
        return False
    seg = p[len(HOME) + 1:].split("/")
    if len(seg) < (3 if seg[0] == "Library" else 2):
        return False
    parent = os.path.realpath(os.path.dirname(p))
    home = os.path.realpath(HOME)
    return parent == home or parent.startswith(home + "/")


def children(path):
    if os.path.islink(path) or not os.path.isdir(path):
        raise Refused("not a folder any more: " + disp(path))
    if os.path.realpath(path) != path:
        raise Refused("reached through a symlink, so it is left alone: " + disp(path))
    try:
        return [os.path.join(path, n) for n in sorted(os.listdir(path))]
    except OSError as e:
        raise Refused(f"cannot read {disp(path)}: {e.strerror}")


def server_rules():
    """rule id -> (safety, folder, command), from this file only."""
    return {rid: (safety, expand(path), cmd)
            for rid, group, safety, title, path, why, cmd in RULES + user_temp_rules()}


def scan_rule_paths(rid, scan_path):
    try:
        with open(scan_path) as f:
            rules = json.load(f).get("rules", [])
    except (OSError, ValueError):
        raise Refused("no scan to check this against")
    for r in rules:
        if r.get("id") == rid:
            return [expand(p) for p in r.get("paths", [])]
    raise Refused("not in the current scan")


def resolve(item_id, hard, scan_path):
    """Turn an id into concrete steps: ("run", cmd) | ("delete", path) | ("trash", path)."""
    if item_id.startswith("rule:"):
        rid = item_id[5:]
        if rid == "pycache":
            return [("run", PYCACHE_CMD)]
        rules = server_rules()
        if rid in rules:
            safety, path, cmd = rules[rid]
            if safety == "keep" or (cmd and cmd.startswith("@")):
                raise Refused("this one is handled by hand, in the app that owns it")
            if cmd:
                return [("run", cmd)]
            kind = "delete" if (safety == "safe" or hard or rid in PERMANENT) else "trash"
            return [(kind, c) for c in children(path)]
        if rid.startswith("cache:") or rid.startswith("cache-rest:"):
            containers = {expand(c) for c, _ in CACHE_CONTAINERS}
            steps = []
            for p in scan_rule_paths(rid, scan_path):
                if p != os.path.normpath(p) or os.path.dirname(p) not in containers:
                    raise Refused("not a cache folder: " + disp(p))
                if os.path.lexists(p):
                    steps += [("delete", c) for c in children(p)]
            return steps
        raise Refused("unknown item")
    if item_id.startswith("file:"):
        p = expand(item_id[5:])
        if not user_path_ok(p):
            raise Refused("outside the folders Headroom is allowed to touch: " + disp(p))
        if not os.path.lexists(p):
            raise Refused("already gone: " + disp(p))
        permanent = hard or os.path.basename(p) in REBUILDABLE or inside_cache_rule(p)
        return [("delete" if permanent else "trash", p)]
    if item_id.startswith("hfrepo:") or item_id.startswith("hforphans:"):
        tag, _, shown = item_id.partition(":")
        p = expand(shown)
        hub = p if tag == "hforphans" else os.path.dirname(p)
        if p != os.path.normpath(p) or hub not in {expand(h) for h in HF_HUBS} or os.path.realpath(hub) != hub:
            raise Refused("not a Hugging Face cache folder: " + disp(p))
        links, shared = hf_links(hub)
        if tag == "hforphans":
            blobs = hf_orphans(hub, links, shared)
            steps = []
        else:
            if p not in links:
                raise Refused("already gone: " + disp(p))
            others = set().union(*[ts for repo, ts in links.items() if repo != p]) if len(links) > 1 else set()
            blobs = sorted(links[p] - others)
            steps = [("delete", p)]
        for b in blobs:                                # only ever files inside this hub's blob store
            if not b.startswith(shared + os.sep) or os.path.islink(b) or not os.path.isfile(b):
                raise Refused("unexpected file in the blob store: " + disp(b))
        return steps + [("delete", b) for b in blobs]
    raise Refused("unknown item")


def inside_cache_rule(p):
    """True for paths inside a folder this file lists as a cache (safe, or a download cache)."""
    for rid, (safety, path, cmd) in server_rules().items():
        if (safety == "safe" or rid in PERMANENT) and p.startswith(path + "/"):
            return True
    return False


def remove(p):
    if os.path.islink(p) or not os.path.isdir(p):
        os.unlink(p)
        return
    shutil.rmtree(p, ignore_errors=True)
    if os.path.lexists(p):
        raise OSError("some files are in use or protected and were left behind")


def to_trash(p):
    if os.path.exists("/usr/bin/trash"):
        r = subprocess.run(["/usr/bin/trash", p], capture_output=True, text=True, timeout=900)
    else:
        r = subprocess.run(["osascript", "-e", "on run argv", "-e",
                            'tell application "Finder" to delete (POSIX file (item 1 of argv) as alias)',
                            "-e", "end run", p], capture_output=True, text=True, timeout=900)
    if r.returncode != 0:
        raise OSError((r.stderr or r.stdout).strip()[-300:] or "could not move it to the Trash")


def run_cmd(cmd):
    env = dict(os.environ)
    env.setdefault("UV_LOCK_TIMEOUT", "30")   # fail fast when another uv process holds the cache
    env["PATH"] = ":".join([expand(p) for p in EXTRA_PATH] + [env.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")])
    r = subprocess.run(["/bin/zsh", "-lc", cmd], env=env, stdin=subprocess.DEVNULL,
                       capture_output=True, text=True, timeout=1800)
    out = (r.stdout + r.stderr).strip()
    if r.returncode == 127:
        raise OSError("the tool for this is not installed or not on PATH")
    if r.returncode != 0:
        raise OSError(out[-300:] or f"exit code {r.returncode}")
    return out[-400:]


def summarise(steps):
    if not steps:
        return "Nothing left to remove"
    if steps[0][0] == "run":
        return "Runs: " + steps[0][1]
    d = sum(1 for k, _ in steps if k == "delete")
    t = len(steps) - d
    parts = []
    if d:
        parts.append(f"Deletes {d} item{'s' if d != 1 else ''} for good")
    if t:
        parts.append(f"Moves {t} item{'s' if t != 1 else ''} to the Trash")
    return " and ".join(parts)


def clean_one(item_id, hard, dry, scan_path):
    res = {"id": item_id, "ok": False, "errors": [], "freed": 0, "trashed": 0, "summary": ""}
    try:
        steps = resolve(item_id, hard, scan_path)
    except Refused as e:
        res["errors"].append(str(e))
        return res
    res["summary"] = summarise(steps)
    if dry:
        res["ok"] = True
        return res
    before = free_bytes()
    failed = 0
    for kind, target in steps:
        try:
            if kind == "run":
                res["output"] = run_cmd(target)
            elif kind == "delete":
                remove(target)
            else:
                to_trash(target)
                res["trashed"] += 1
        except Exception as e:  # noqa: BLE001 - report every failure to the UI
            failed += 1
            if len(res["errors"]) < 4:
                res["errors"].append(f"{target if kind == 'run' else disp(target)}: {e}")
    if failed > len(res["errors"]):
        res["errors"].append(f"and {failed - len(res['errors'])} more")
    res["ok"] = failed == 0
    res["free"] = free_bytes()
    res["freed"] = max(0, res["free"] - before)
    try:
        with open(os.path.join(os.path.dirname(os.path.abspath(scan_path)), "headroom-actions.log"), "a") as f:
            f.write(json.dumps({"at": time.strftime("%Y-%m-%d %H:%M:%S"), "id": item_id, "hard": bool(hard),
                                "did": res["summary"], "ok": res["ok"], "freed": res["freed"],
                                "errors": res["errors"]}, ensure_ascii=False) + "\n")
    except OSError:
        pass
    return res


def in_home(p):
    home = os.path.realpath(HOME)
    real = os.path.realpath(p)
    return real == home or real.startswith(home + "/")


def list_folder(shown, budget=6.0):
    """Live contents of one folder in the home folder, largest first. Read-only.
    Folder sizes are measured on the spot; anything not finished within `budget`
    seconds is returned as a partial ("at least") figure."""
    p = expand(shown)
    if not p.startswith("/") or p != os.path.normpath(p) or os.path.islink(p) or not os.path.isdir(p):
        raise Refused("not a folder: " + disp(p))
    if not in_home(p):
        raise Refused("Headroom only looks inside your home folder")
    deadline = time.time() + budget
    try:
        with os.scandir(p) as it:
            raw = [e.path for e in it]
    except OSError as e:
        raise Refused(f"macOS would not open {disp(p)}: {e.strerror}")

    def one(path):
        try:
            st = os.lstat(path)
        except OSError:
            return None
        out = {"name": os.path.basename(path), "path": disp(path), "dir": False,
               "bytes": 0, "mtime": int(st.st_mtime)}
        if stat.S_ISLNK(st.st_mode):
            out["link"] = True
        elif stat.S_ISDIR(st.st_mode):
            total, back, files, newest, partial = measure(path, deadline)
            out.update(dir=True, bytes=total, files=files, mtime=int(max(newest, st.st_mtime)))
            if partial:
                out["partial"] = True
            else:
                with_frees(out, back)
        else:
            out["bytes"] = st.st_blocks * 512
            with_frees(out, private_bytes(path))
        return out

    with ThreadPoolExecutor(6) as ex:
        entries = [e for e in ex.map(one, raw) if e]
    entries.sort(key=lambda e: -e["bytes"])
    rest = entries[250:]
    return {"path": disp(p), "entries": entries[:250],
            "rest": {"count": len(rest), "bytes": sum(e["bytes"] for e in rest)} if rest else None}


def reveal(shown):
    p = expand(shown)
    if not p.startswith("/") or p != os.path.normpath(p) or not os.path.lexists(p):
        raise Refused("not there any more: " + disp(p))
    if not (in_home(os.path.dirname(p)) or p.startswith("/Applications/")):
        raise Refused("Headroom only shows items in your home folder or Applications")
    subprocess.run(["open", "-R", p], timeout=20)


def start_rescan(scan_path):
    if SCAN["running"]:
        return
    SCAN.update(running=True, progress="Starting", error="")

    def work():
        try:
            p = subprocess.Popen([sys.executable, os.path.abspath(__file__), "scan", "--out", scan_path],
                                 stderr=subprocess.PIPE, text=True)
            for line in p.stderr:
                line = line.strip()
                SCAN["progress"] = (line.split(" files")[0].strip() + " files") if " files  " in line else line[:80]
            if p.wait() != 0:
                SCAN["error"] = "The scan stopped early."
        except Exception as e:  # noqa: BLE001
            SCAN["error"] = str(e)
        finally:
            SCAN["running"] = False
    threading.Thread(target=work, daemon=True).start()


def make_handler(token, port, scan_path):
    import http.server
    hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}
    origins = {"http://" + h for h in hosts}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def send(self, code, body, ctype="application/json; charset=utf-8"):
            if not isinstance(body, bytes):
                body = json.dumps(body, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(body)

        def guard(self, need_token=True):
            STATE["last"] = time.time()
            origin = self.headers.get("Origin")
            if self.headers.get("Host") not in hosts or (origin and origin not in origins):
                self.send(403, {"error": "Headroom only answers its own window."})
                return False
            if need_token and not hmac.compare_digest(self.headers.get("X-Headroom-Token", ""), token):
                self.send(403, {"error": "This window is out of date. Reopen Headroom."})
                return False
            return True

        def status(self):
            sv = os.statvfs(DATA if os.path.isdir(DATA) else "/")
            return {"free": sv.f_bavail * sv.f_frsize, "total": sv.f_blocks * sv.f_frsize,
                    "scanning": SCAN["running"], "progress": SCAN["progress"], "scanError": SCAN["error"],
                    "hasScan": os.path.exists(scan_path)}

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path == "/api/ping":
                if self.guard(False):
                    self.send(200, {"app": "headroom"})
            elif path == "/api/status":
                if self.guard():
                    self.send(200, self.status())
            elif path in ("/", "/index.html"):
                if self.guard(False):
                    with open(os.path.join(HERE, "index.html"), "rb") as f:
                        page = f.read()
                    head = ('<!doctype html><meta charset="utf-8">'
                            '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">'
                            '<script>window.HEADROOM={token:"%s"}</script>' % token).encode()
                    self.send(200, head + page, "text/html; charset=utf-8")
            elif path == "/scan.json":
                if self.guard():
                    try:
                        with open(scan_path, "rb") as f:
                            self.send(200, f.read())
                    except OSError:
                        self.send(404, {"error": "No scan yet."})
            else:
                self.send(404, {"error": "Not found."})

        def do_POST(self):
            if not self.guard():
                return
            path = self.path.split("?", 1)[0]
            try:
                n = int(self.headers.get("Content-Length", "0"))
                if not self.headers.get("Content-Type", "").startswith("application/json") or n > 1 << 20:
                    raise ValueError
                body = json.loads(self.rfile.read(n) or b"{}")
                if not isinstance(body, dict):
                    raise ValueError
            except ValueError:
                self.send(400, {"error": "Bad request."})
                return
            if path == "/api/clean":
                ids = body.get("ids")
                if not isinstance(ids, list) or len(ids) > 2000 or not all(isinstance(i, str) for i in ids):
                    self.send(400, {"error": "Bad request."})
                    return
                dry, hard = bool(body.get("dryRun")), bool(body.get("hard"))
                if dry:
                    self.send(200, {"results": [clean_one(i, hard, True, scan_path) for i in ids]})
                    return
                STATE["busy"] += 1
                try:
                    with CLEAN_LOCK:
                        results = [clean_one(i, hard, False, scan_path) for i in ids]
                finally:
                    STATE["busy"] -= 1
                    STATE["last"] = time.time()
                self.send(200, {"results": results})
            elif path in ("/api/list", "/api/reveal"):
                shown = body.get("path")
                if not isinstance(shown, str) or len(shown) > 4096:
                    self.send(400, {"error": "Bad request."})
                    return
                try:
                    self.send(200, list_folder(shown) if path == "/api/list" else (reveal(shown) or {"ok": True}))
                except Refused as e:
                    self.send(400, {"error": str(e)})
            elif path == "/api/rescan":
                start_rescan(scan_path)
                self.send(200, self.status())
            elif path == "/api/quit":
                self.send(200, {"ok": True})
                threading.Thread(target=lambda: (time.sleep(0.3), os._exit(0)), daemon=True).start()
            else:
                self.send(404, {"error": "Not found."})
    return Handler


def open_window(url):
    chrome = "/Applications/Google Chrome.app"
    if os.path.isdir(chrome):
        if subprocess.run(["open", "-na", chrome, "--args", "--app=" + url]).returncode == 0:
            return
    import webbrowser
    webbrowser.open(url)


def run_app(args):
    import http.server
    import urllib.request
    url = f"http://127.0.0.1:{args.port}/"
    if args.port:
        try:  # already running: just bring up a window
            with urllib.request.urlopen(url + "api/ping", timeout=1) as r:
                if json.load(r).get("app") == "headroom":
                    if not args.no_open:
                        open_window(url)
                    return
        except Exception:  # noqa: BLE001 - nothing listening, start fresh
            pass
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    token = secrets.token_urlsafe(24)
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), http.server.BaseHTTPRequestHandler)
    port = httpd.server_address[1]          # --port 0 lets the system pick a free one
    httpd.RequestHandlerClass = make_handler(token, port, args.out)
    url = f"http://127.0.0.1:{port}/"
    httpd.daemon_threads = True   # with no scan on disk yet, the page asks for one as soon as it loads

    def watchdog():
        while True:
            time.sleep(5 if args.stay else 30)
            if args.stay:                      # run by the native app: live exactly as long as it does
                if os.getppid() == 1:
                    os._exit(0)
            elif not SCAN["running"] and not STATE["busy"] and time.time() - STATE["last"] > IDLE_EXIT:
                os._exit(0)
    threading.Thread(target=watchdog, daemon=True).start()
    print(f"HEADROOM_URL {url}", flush=True)   # the native wrapper reads this line
    if not args.no_open:
        open_window(url)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Headroom: Mac storage scanner and cleanup app")
    ap.add_argument("command", nargs="?", default="scan", choices=["scan", "app", "serve"])
    ap.add_argument("--root", help="folder to scan (default: the whole Data volume)")
    ap.add_argument("--out", default=os.path.join(HERE, "scan.json"))
    ap.add_argument("--min-mb", type=int, default=200, help="smallest folder kept in the map")
    ap.add_argument("--depth", type=int, default=9, help="deepest level kept in the map")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--no-open", action="store_true", help="app mode: do not open a window")
    ap.add_argument("--stay", action="store_true", help="app mode: run until the parent process exits")
    a = ap.parse_args()
    run_scan(a) if a.command == "scan" else run_app(a)
