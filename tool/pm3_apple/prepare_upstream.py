#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Apply a small, checked overlay to RRG's experimental library target."""

from __future__ import annotations

import argparse
from pathlib import Path
import shutil


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"expected exactly one {label}; found {count}")
    return text.replace(old, new, 1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--shim", required=True, type=Path)
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()

    source = args.source.resolve()
    shim = args.shim.resolve()
    cmake_path = source / "client" / "experimental_lib" / "CMakeLists.txt"
    pm3_header = source / "client" / "include" / "pm3.h"
    pm3_source = source / "client" / "src" / "pm3.c"
    cmdparser_source = source / "client" / "src" / "cmdparser.c"
    util_source = source / "client" / "src" / "util.c"
    source_shim_header = shim / "include" / "TagentraPM3Core.h"
    source_shim_source = shim / "src" / "TagentraPM3Core.c"

    for required in (cmake_path, pm3_header, pm3_source, cmdparser_source, util_source, source_shim_header, source_shim_source):
        if not required.is_file():
            raise RuntimeError(f"required file is missing: {required}")

    embedded_shim = source / "client" / "experimental_lib" / "tagentra_shim"
    (embedded_shim / "include").mkdir(parents=True, exist_ok=True)
    (embedded_shim / "src").mkdir(parents=True, exist_ok=True)
    shim_header = embedded_shim / "include" / source_shim_header.name
    shim_source = embedded_shim / "src" / source_shim_source.name
    shutil.copy2(source_shim_header, shim_header)
    shutil.copy2(source_shim_source, shim_source)

    api = pm3_header.read_text(encoding="utf-8")
    for symbol in ("pm3_open", "pm3_console", "pm3_grabbed_output_get", "pm3_close"):
        if symbol not in api:
            raise RuntimeError(f"RRG API changed: {symbol} is absent from {pm3_header}")

    text = cmake_path.read_text(encoding="utf-8")
    text = replace_once(
        text,
        "# If cross-compiled, we need to init source and build.\nif (CMAKE_TOOLCHAIN_FILE)\n",
        "# If cross-compiled, we need to init source and build.\nif (CMAKE_TOOLCHAIN_FILE)\n"
        "    if (APPLE AND DEFINED TAGENTRA_EXTERNAL_CFLAGS)\n"
        "        set(CFLAGS_EXTERNAL_LIB \"CFLAGS=${TAGENTRA_EXTERNAL_CFLAGS}\")\n"
        "    endif()\n",
        "cross-compilation block",
    )
    text = replace_once(
        text,
        "add_library(pm3rrg_rdv4 SHARED\n",
        "add_library(pm3rrg_rdv4 SHARED\n"
        f"        {shim_source.as_posix()}\n",
        "experimental library target",
    )
    text = replace_once(
        text,
        "target_compile_definitions(pm3rrg_rdv4 PRIVATE LIBPM3)",
        "target_compile_definitions(pm3rrg_rdv4 PRIVATE LIBPM3 TAGENTRA_PM3_IOS "
        f"TAGENTRA_PM3_REVISION=\\\"{args.revision}\\\")\n"
        "set_target_properties(pm3rrg_rdv4 PROPERTIES\n"
        "        FRAMEWORK TRUE\n"
        "        OUTPUT_NAME TagentraPM3Core\n"
        "        MACOSX_FRAMEWORK_IDENTIFIER org.tagentra.pm3core\n"
        f"        PUBLIC_HEADER \"{shim_header.as_posix()}\"\n"
        "        C_VISIBILITY_PRESET hidden\n"
        "        CXX_VISIBILITY_PRESET hidden\n"
        "        VISIBILITY_INLINES_HIDDEN YES\n"
        ")",
        "LIBPM3 compile definition",
    )
    text = replace_once(
        text,
        "target_include_directories(pm3rrg_rdv4 PRIVATE\n",
        "target_include_directories(pm3rrg_rdv4 PRIVATE\n"
        f"        {shim_header.parent.as_posix()}\n",
        "library include list",
    )
    text = replace_once(
        text,
        "    set(ADDITIONAL_LNK ${ADDITIONAL_LNK} -Wl,-undefined,dynamic_lookup)\n",
        "    # Tagentra requires all symbols to resolve when producing the framework.\n",
        "Apple dynamic_lookup linker option",
    )
    cmake_path.write_text(text, encoding="utf-8", newline="\n")

    util = util_source.read_text(encoding="utf-8")
    function_start = "int kbd_enter_pressed(void) {\n"
    if util.count(function_start) != 2:
        raise RuntimeError("RRG API changed: expected two kbd_enter_pressed implementations")
    util = util.replace(
        function_start,
        "extern int tagentra_pm3_should_cancel(void);\n"
        "int kbd_enter_pressed(void) {\n"
        "    if (tagentra_pm3_should_cancel()) {\n"
        "        return 1;\n"
        "    }\n",
    )
    util_source.write_text(util, encoding="utf-8", newline="\n")

    cmdparser = cmdparser_source.read_text(encoding="utf-8")
    system_call = (
        "#else\n"
        "    ret = system(command);\n"
        "#endif\n"
    )
    ios_system_call = (
        "#elif defined(TAGENTRA_PM3_IOS)\n"
        "    // iOS marks system() unavailable; shell escapes are unsupported.\n"
        "    (void)command;\n"
        "    ret = -1;\n"
        "#else\n"
        "    ret = system(command);\n"
        "#endif\n"
    )
    if cmdparser.count(system_call) == 1:
        cmdparser = cmdparser.replace(system_call, ios_system_call, 1)
    elif "system(" in cmdparser:
        raise RuntimeError("RRG system command implementation changed")
    cmdparser_source.write_text(cmdparser, encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main()
