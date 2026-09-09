#!/usr/bin/env python3
"""Fail when an RRG candidate changes the reviewed client write surface."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import Counter
from pathlib import Path


PATTERNS = (
    ("managed_helper", re.compile(r"\b(?:saveFile\w*|pm3_save_\w*|newfilenamemcopy\w*|json_dump_file)\s*\(")),
    ("fopen_write", re.compile(r"\b(?:fopen|freopen)\s*\([^;]{0,300}?,\s*\"[^\"]*[wax+][^\"]*\"", re.S)),
    ("open_write", re.compile(r"\bopen\s*\([^;]{0,300}?\bO_(?:CREAT|WRONLY|RDWR|TRUNC|APPEND)\b", re.S)),
    ("cpp_stream", re.compile(r"\b(?:std::)?(?:ofstream|fstream)\s+[A-Za-z_]")),
    ("lua_io", re.compile(r"\bio\.(?:open|tmpfile)\s*\(")),
    ("lua_temporary", re.compile(r"\bos\.tmpname\s*\(")),
    ("filesystem_mutation", re.compile(r"\b(?:mkdir|rename|remove|mkstemp)\s*\(")),
    ("history_write", re.compile(r"\b(?:write_history|linenoiseHistorySave)\s*\(")),
)

SOURCE_SUFFIXES = {".c", ".cc", ".cpp", ".h", ".hpp", ".lua"}
USER_STATE_FILES = {"preferences.c", "ui.c", "pm3line.c", "proxmark3.c"}
DEVELOPER_ONLY_PARTS = {"tools", "tests", "experimental_lib"}
DEVELOPER_ONLY_FILES = {
    Path("deps/hardnested/hardnested_bruteforce.c"),
    Path("deps/hardnested/hardnested_tables.c"),
}


def normalize(value: str) -> str:
    return re.sub(r"\s+", " ", value.strip())[:240]


def category(relative: Path, kind: str, excerpt: str) -> str:
    if relative in DEVELOPER_ONLY_FILES or any(
        part in DEVELOPER_ONLY_PARTS for part in relative.parts
    ):
        return "developer_only"
    if kind == "managed_helper":
        return "managed_save_path"
    if kind == "lua_temporary" or (kind == "lua_io" and "tmpfile" in excerpt):
        return "system_temporary"
    if kind == "lua_io":
        return "storage_cwd"
    if relative.name in USER_STATE_FILES:
        return "user_root"
    return "storage_cwd"


def scan(source: Path) -> list[dict[str, object]]:
    client = source.resolve() / "client"
    if not client.is_dir():
        raise SystemExit(f"RRG client directory is missing: {client}")
    sites: list[dict[str, object]] = []
    seen: set[tuple[str, str, int]] = set()
    for path in sorted(client.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in SOURCE_SUFFIXES:
            continue
        relative = path.relative_to(client)
        text = path.read_text(encoding="utf-8", errors="replace")
        for kind, pattern in PATTERNS:
            for match in pattern.finditer(text):
                line = text.count("\n", 0, match.start()) + 1
                key = (relative.as_posix(), kind, line)
                if key in seen:
                    continue
                seen.add(key)
                excerpt = normalize(match.group(0))
                sites.append(
                    {
                        "path": relative.as_posix(),
                        "line": line,
                        "kind": kind,
                        "category": category(relative, kind, excerpt),
                        "excerpt": excerpt,
                    }
                )
    return sorted(sites, key=lambda value: (str(value["path"]), int(value["line"]), str(value["kind"])))


def signature(sites: list[dict[str, object]]) -> str:
    stable = [
        f'{site["path"]}|{site["kind"]}|{site["category"]}|{site["excerpt"]}'
        for site in sites
    ]
    return hashlib.sha256("\n".join(stable).encode()).hexdigest()


def summary(sites: list[dict[str, object]]) -> dict[str, object]:
    return {
        "schema": 1,
        "site_count": len(sites),
        "category_counts": dict(sorted(Counter(str(site["category"]) for site in sites).items())),
        "sha256": signature(sites),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument(
        "--baseline",
        type=Path,
        default=Path(__file__).with_name("io_audit_baseline.json"),
    )
    parser.add_argument("--print-baseline", action="store_true")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()

    sites = scan(args.source)
    actual = summary(sites)
    if args.report:
        args.report.write_text(json.dumps({"summary": actual, "sites": sites}, indent=2) + "\n", encoding="utf-8")
    if args.print_baseline:
        print(json.dumps(actual, indent=2))
        return
    expected = json.loads(args.baseline.read_text(encoding="utf-8"))
    if actual != expected:
        print("RRG file-I/O audit changed; review the generated report before updating the baseline.")
        print("expected:", json.dumps(expected, sort_keys=True))
        print("actual:  ", json.dumps(actual, sort_keys=True))
        raise SystemExit(1)
    print(f'RRG file-I/O audit OK: {actual["site_count"]} reviewed sites ({actual["sha256"][:12]})')


if __name__ == "__main__":
    main()
