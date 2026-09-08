#!/usr/bin/env python3
"""Turn a tested candidate into the current record for a review PR."""
import json
from pathlib import Path

path = Path(__file__).with_name("refs.json")
data = json.loads(path.read_text(encoding="utf-8"))
candidate = data.get("candidate")
if not candidate:
    raise SystemExit("no candidate is registered")
current = data["current"]
data.setdefault("history", {})[current["tag"]] = current["revision"]
data.setdefault("history", {})[candidate["tag"]] = candidate["revision"]
data["current"] = {
    "tag": candidate["tag"],
    "revision": candidate["revision"],
    "adapter_revision": 1,
}
data["candidate"] = None
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
