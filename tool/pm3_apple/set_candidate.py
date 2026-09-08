#!/usr/bin/env python3
"""Write a fully resolved upstream candidate without promoting it."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--revision", required=True)
args = parser.parse_args()
if len(args.revision) != 40 or any(c not in "0123456789abcdef" for c in args.revision):
    parser.error("revision must be a full lowercase commit SHA")
path = Path(__file__).with_name("refs.json")
data = json.loads(path.read_text(encoding="utf-8"))
data["candidate"] = {"tag": args.tag, "revision": args.revision}
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
