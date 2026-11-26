#!/bin/zsh
# Builds and runs the engine tests. They work inside throwaway folders under the system temp
# folder; nothing in the real home is touched.
#   ./test.sh              every test, then the cross-check with scan.py if python3 is installed
#   ./test.sh <words>      only tests whose name contains <words>
#   ./test.sh --no-python  skip the cross-check
set -euo pipefail
cd "${0:A:h}"
BIN=$(mktemp -d)/headroom-tests
swiftc -Onone -parse-as-library -target "$(uname -m)-apple-macos14.0" -o "$BIN" app/Engine/*.swift app/Tests/*.swift
if [[ "${1:-}" != "" && "${1:-}" != "--no-python" ]]; then
  "$BIN" "$1"
  exit $?
fi
"$BIN"
[[ "${1:-}" == "--no-python" ]] && exit 0
command -v python3 >/dev/null || { echo "python3 not found: skipping the cross-check with scan.py"; exit 0; }
# Both scanners measure the same fixture home; their reports must agree.
BASE=$(mktemp -d)/crosscheck
mkdir -p "$BASE"
trap 'chmod -R u+rwx "$BASE" 2>/dev/null; rm -rf "$BASE"' EXIT
"$BIN" --make-fixture "$BASE/home" "$BASE/swift"
HOME_REAL=$(cd "$BASE/home" && pwd -P)
"$BIN" --scan-fixture "$HOME_REAL" "$(cd "$BASE" && pwd -P)/swift"
HOME="$HOME_REAL" python3 scan.py scan --root "$HOME_REAL" --out "$BASE/python.json" 2>/dev/null
python3 app/Tests/compare.py "$BASE/python.json" "$BASE/swift/scan.json"
