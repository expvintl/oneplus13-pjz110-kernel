#!/usr/bin/env python3
"""Merge every ABI symbol list referenced by BUILD.bazel into one whitelist.

The vendor build keeps unused GKI exports via CONFIG_UNUSED_KSYMS_WHITELIST;
this recreates that union so module CRC resolution matches the stock kernel.
"""
import pathlib
import re
import sys

src = pathlib.Path(sys.argv[1])
dest = pathlib.Path(sys.argv[2])
bazel = (src / 'BUILD.bazel').read_text()
section = bazel.split('name = "aarch64_additional_kmi_symbol_lists"', 1)[1].split('visibility =', 1)[0]
paths = ['android/abi_gki_aarch64'] + re.findall(r'"(android/abi_gki_aarch64_[^"]+)"', section)

symbols = set()
for name in paths:
    for line in (src / name).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith(('#', '[')):
            continue
        if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', line):
            raise SystemExit(f'unrecognised ABI symbol in {name}: {line!r}')
        symbols.add(line)

dest.write_text(''.join(s + '\n' for s in sorted(symbols)))
print(f'{len(symbols)} ABI symbols -> {dest}')
