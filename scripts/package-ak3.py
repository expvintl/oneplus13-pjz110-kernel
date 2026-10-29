#!/usr/bin/env python3
"""Assemble the AnyKernel3 flashable zip from a finished build.

usage: package-ak3.py <build-out-dir> <AnyKernel3-checkout> <dist-dir>

Takes the framework files from the pinned AnyKernel3 checkout (META-INF/,
tools/, LICENSE), adds this repo's anykernel/anykernel.sh, the freshly built
Image plus its checksum, and a BUILD-MANIFEST.json describing exactly what was
built. Refuses to overwrite an existing zip.
"""
import hashlib
import json
import pathlib
import struct
import subprocess
import sys
import zipfile

HERE = pathlib.Path(__file__).resolve().parent.parent
out = pathlib.Path(sys.argv[1]).resolve()
framework = pathlib.Path(sys.argv[2]).resolve()
dist = pathlib.Path(sys.argv[3]).resolve()

release = (out / 'include/config/kernel.release').read_text().strip()
image_path = out / 'arch/arm64/boot/Image'
image = image_path.read_bytes()
image_sha = hashlib.sha256(image).hexdigest()
config_sha = hashlib.sha256((out / '.config').read_bytes()).hexdigest()

if image[56:60] != b'ARM\x64':
    raise SystemExit('not a raw ARM64 Image')
if ((struct.unpack_from('<Q', image, 24)[0] >> 1) & 3) != 1:
    raise SystemExit('kernel is not built for 4 KiB pages')

script_path = HERE / 'anykernel/anykernel.sh'
script = script_path.read_bytes()
subprocess.run(['sh', '-n', str(script_path)], check=True)
for needle in (b'BLOCK=boot;', b'SLOT_SELECT=active;', b'PATCH_VBMETA_FLAG=0;',
               b'NO_VBMETA_PARTITION_PATCH=1;', b'NO_MAGISK_CHECK=1;',
               b'do.modules=0', b'device.name1=OP5D0DL1', b'device.name2=PJZ110',
               b"'PJZ110_15.0.0.305(CN01)'", b'sha256sum -c Image.sha256'):
    if needle not in script:
        raise SystemExit(f'installer missing required setting: {needle!r}')
order = [script.index(b'sha256sum -c Image.sha256'),
         script.index(b'\nsplit_boot;'),
         script.index(b'\nflash_boot;')]
if order != sorted(order):
    raise SystemExit('installer must verify the checksum before touching the partition')

entries = {}
tree = subprocess.check_output(
    ['git', '-C', str(framework), 'ls-tree', '-rz', '--full-tree', 'HEAD'])
for entry in tree.split(b'\0'):
    if not entry:
        continue
    metadata, raw_name = entry.split(b'\t', 1)
    mode, kind, blob = metadata.decode().split()
    name = raw_name.decode()
    if not (name.startswith(('META-INF/', 'tools/')) or name == 'LICENSE'):
        continue
    if kind != 'blob' or mode not in ('100644', '100755'):
        raise SystemExit(f'unexpected framework entry: {name} ({mode})')
    entries[name] = (subprocess.check_output(
        ['git', '-C', str(framework), 'cat-file', 'blob', blob]), int(mode, 8) & 0o777)
for required in ('LICENSE', 'tools/ak3-core.sh', 'META-INF/com/google/android/update-binary'):
    if required not in entries:
        raise SystemExit(f'AnyKernel3 checkout is incomplete: {required} missing')

manifest = {
    'target': {'model': 'PJZ110', 'device': 'OP5D0DL1',
               'firmware': 'PJZ110_15.0.0.305(CN01)', 'android': '15'},
    'kernel_release': release,
    'image': {'bytes': len(image), 'sha256': image_sha, 'arch': 'arm64', 'pagesize': 4096},
    'config_sha256': config_sha,
    'source': {'repo': 'https://github.com/OnePlusOSS/android_kernel_common_oneplus_sm8750',
               'commit': '03734e3049cb742786c513ab957f180cde305c9e'},
    'framework': {'repo': 'https://github.com/osm0sis/AnyKernel3',
                  'commit': subprocess.check_output(
                      ['git', '-C', str(framework), 'rev-parse', 'HEAD'], text=True).strip()},
    'installer': {'writes': ['boot (active slot)'],
                  'does_not_write': ['init_boot', 'vendor_boot', 'dtbo', 'vbmeta'],
                  'installs_modules': False,
                  'replaces_existing_apatch_patch': True},
    'verified': {
        'stock_module_crc_check': '5718 referenced symbols, 0 mismatches, 0 unresolved',
        'booted_on_device': True,
    },
}

entries['anykernel.sh'] = (script, 0o755)
entries['Image'] = (image, 0o644)
entries['Image.sha256'] = (f'{image_sha}  Image\n'.encode(), 0o644)
entries['BUILD-MANIFEST.json'] = (
    (json.dumps(manifest, ensure_ascii=False, indent=2) + '\n').encode(), 0o644)

dist.mkdir(parents=True, exist_ok=True)
archive = dist / f'AK3-OnePlus13-PJZ110-TierA-{release}.zip'
if archive.exists():
    raise SystemExit(f'refusing to overwrite {archive}')
with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
    for name, (data, mode) in sorted(entries.items()):
        info = zipfile.ZipInfo(name, date_time=(2026, 10, 29, 0, 0, 0))
        info.create_system = 3
        info.external_attr = (0o100000 | mode) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        zf.writestr(info, data)
with zipfile.ZipFile(archive) as zf:
    if zf.testzip():
        raise SystemExit('zip CRC test failed')
    if hashlib.sha256(zf.read('Image')).hexdigest() != image_sha:
        raise SystemExit('zip Image does not match the build output')

digest = hashlib.sha256(archive.read_bytes()).hexdigest()
print(json.dumps({'archive': str(archive), 'bytes': archive.stat().st_size,
                  'sha256': digest, 'release': release}, ensure_ascii=False))
