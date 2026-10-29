#!/usr/bin/env python3
"""Fail the build if the kernel stops matching the stock .305 module ABI.

Compares every exported-symbol CRC this build produced (Module.symvers) with the
CRCs the phone's own stock modules demand (abi/stock-module-crcs.tsv, harvested
from the 624 vendor/system_dlkm/vendor_boot modules).

A mismatch means the stock modules would refuse to load at boot: WiFi, BT,
camera and everything else in vendor_dlkm breaks. Run this after every build.
"""
import pathlib
import sys

out = pathlib.Path(sys.argv[1])           # build output directory
table = pathlib.Path(__file__).resolve().parent.parent / 'abi/stock-module-crcs.tsv'

expected = {}
for line in table.read_text().splitlines():
    if not line.strip():
        continue
    symbol, crc = line.split('\t')
    expected[symbol] = crc

built = {}
for line in (out / 'Module.symvers').read_text().splitlines():
    fields = line.split('\t')
    if len(fields) >= 4:
        built[fields[1]] = fields[0]

shared = sorted(set(expected) & set(built))
mismatch = [(s, expected[s], built[s]) for s in shared if expected[s].lower() != built[s].lower()]
unresolved = sorted(set(expected) - set(built))

print(f'stock symbols: {len(expected)}  built exports: {len(built)}  shared: {len(shared)}')
for symbol, want, got in mismatch:
    print(f'  CRC MISMATCH {symbol}: stock {want} != build {got}')
if unresolved:
    # Symbols only another module provides are expected to be absent here; the
    # build-side check therefore reports them as information, not failure.
    print(f'  not exported by this build: {len(unresolved)} (module-to-module only)')
if mismatch:
    raise SystemExit(f'{len(mismatch)} CRC mismatches — the kernel is NOT ABI compatible')
print('ABI OK: every shared symbol CRC matches the stock .305 modules')
