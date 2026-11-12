"""Write www/bundle.json: this bundle's version and a sha256 of every file in it.

The iPhone app compares its own bundle.json with the one published for live updates
(GitHub release "ota") to decide whether a new screen bundle can be applied without
an App Store update: only index.html may differ; any other changed file needs a new build.
Run after build.py --www and after capacitor.js and vendor/ are in place.
"""
import hashlib
import json
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
www = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "www"
m = re.search(r'VERSION\s*=\s*"([^"]+)"', (root / "sw.js").read_text(encoding="utf-8"))
ver = m.group(1) if m else "ppi-v0"
files = {}
for p in sorted(www.rglob("*")):
    if p.is_file() and p.name not in ("bundle.json", "SOURCES.txt"):
        files[p.relative_to(www).as_posix()] = hashlib.sha256(p.read_bytes()).hexdigest()
(www / "bundle.json").write_text(json.dumps({"ver": ver, "files": files}, indent=1), encoding="utf-8")
print(f"www/bundle.json: {ver}, {len(files)} files")
