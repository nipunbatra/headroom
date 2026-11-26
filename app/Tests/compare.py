#!/usr/bin/env python3
"""Checks that the Swift scanner and scan.py describe the same fixture the same way.

    python3 compare.py python.json swift.json

Order of equal-sized items and the read dates of files are left out: both scanners read the
fixture, which moves read dates, and neither promises an order between ties.
"""
import json
import sys


def tree(n):
    return {"n": n["n"], "s": n["s"], "f": n.get("f"), "r": n.get("r"), "t": n.get("t"), "k": n.get("k"), "o": n.get("o"),
            "c": sorted((tree(c) for c in n.get("c", [])), key=lambda c: c["n"])}


def item(i):
    return {k: i.get(k) for k in ("name", "kind", "path", "bytes", "frees", "dir", "flag", "note")}


def shape(d):
    return {
        "root": d["root"],
        "stats": d["stats"],
        "scanned": d["disk"]["scanned"],
        "unique": d["disk"].get("unique"),
        "tree": tree(d["tree"]),
        "kinds": {k["kind"]: (k["bytes"], k["files"]) for k in d["kinds"]},
        "exts": {e["ext"]: (e["bytes"], e["files"]) for e in d.get("exts", [])},
        "rules": {r["id"]: {"group": r["group"], "safety": r["safety"], "title": r["title"], "paths": sorted(r["paths"]),
                            "bytes": r["bytes"], "frees": r.get("frees"), "cmd": r.get("cmd"), "perm": r.get("perm"), "why": r["why"],
                            "items": {i["id"]: item(i) for i in r.get("items", [])}, "rest": r.get("itemsRest")}
                  for r in d["rules"]},
        "found": {f["path"]: (f["tag"], f["bytes"], f.get("files"), f.get("frees"), f.get("projectMtime")) for f in d["found"]},
        "tagTotals": d["tagTotals"],
        "bigFiles": {f["path"]: (f["bytes"], f["kind"], f.get("frees"), f["mtime"]) for f in d["bigFiles"]},
        "dupes": sorted((g["bytes"], sorted(f["path"] for f in g["files"])) for g in d["dupes"]),
        "downloads": {f["name"]: (f["bytes"], f["dir"], f.get("frees"), f["mtime"]) for f in d["downloads"]},
        "apps": {a["path"]: (a["bytes"], sorted((l["path"], l["bytes"]) for l in a.get("leftovers", []))) for a in d["apps"]},
        # Apple's plist reader accepts a few files Python's rejects, so an id only one side found is not a difference
        "ids": {a["path"]: a["bundleId"] for a in d["apps"] if a.get("bundleId")},
        "denied": sorted(d.get("denied", [])),
    }


def diff(a, b, where, out):
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b), key=str):
            if k not in a:
                out.append(f"{where}/{k}: only in the Swift scan: {json.dumps(b[k])[:160]}")
            elif k not in b:
                out.append(f"{where}/{k}: only in the Python scan: {json.dumps(a[k])[:160]}")
            else:
                diff(a[k], b[k], f"{where}/{k}", out)
    elif isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        for i, (x, y) in enumerate(zip(a, b)):
            diff(x, y, f"{where}[{i}]", out)
    elif a != b and not (isinstance(a, (list, tuple)) and isinstance(b, (list, tuple)) and list(a) == list(b)):
        out.append(f"{where}: python {json.dumps(a)[:120]} != swift {json.dumps(b)[:120]}")


py, sw = (shape(json.load(open(p))) for p in sys.argv[1:3])
both = set(py["ids"]) & set(sw["ids"])
py["ids"], sw["ids"] = ({k: v for k, v in d["ids"].items() if k in both} for d in (py, sw))
problems = []
diff(py, sw, "", problems)
if problems:
    print(f"cross-check FAILED: {len(problems)} differences")
    for p in problems[:60]:
        print("  " + p)
    sys.exit(1)
print(f"cross-check ok: both scanners agree on {py['stats']['files']} files, {len(py['rules'])} rules, "
      f"{len(py['found'])} project folders, {len(py['bigFiles'])} large files, {len(py['dupes'])} duplicate group(s)")
