#!/usr/bin/env python3
"""Finalize the Flutter plugin manifest from a downloaded Release asset."""
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("zip", type=Path, help="downloaded immutable XCFramework ZIP")
args = parser.parse_args()
if not args.zip.is_file():
    parser.error("release ZIP does not exist")
checksum = subprocess.check_output(
    ["swift", "package", "compute-checksum", str(args.zip.resolve())],
    text=True,
).strip()
if len(checksum) != 64 or any(c not in "0123456789abcdef" for c in checksum):
    raise SystemExit("swift package returned an invalid checksum")
root = Path(__file__).resolve().parents[2]
template = root / "packages/tagentra_pm3/ios/Package.swift.in"
manifest = template.with_name("Package.swift")
text = template.read_text(encoding="utf-8")
if text.count("@CHECKSUM@") != 1:
    raise SystemExit("manifest template checksum marker changed")
manifest.write_text(text.replace("@CHECKSUM@", checksum), encoding="utf-8")
print(checksum)
