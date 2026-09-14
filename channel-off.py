#!/usr/bin/env python3
"""Matikan channel di config OpenClaw tanpa lewat CLI (fallback)."""
import json, os, sys, tempfile
p, ch = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d.setdefault("channels", {}).setdefault(ch, {})["enabled"] = False
fd, t = tempfile.mkstemp(dir=os.path.dirname(p))
os.close(fd)
with open(t, "w") as f:
    json.dump(d, f, indent=2)
os.chmod(t, 0o600)
os.replace(t, p)
print("ok")
