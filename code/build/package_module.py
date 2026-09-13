#!/usr/bin/env python3
"""Build a deterministic KernelSU ZIP from this repository; no Android SDK needed."""
import argparse
import hashlib
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
MODULE = REPO / 'code/module'


def payload():
    files = {}
    for line in (MODULE/'payload.sha256').read_text(encoding='utf-8').splitlines():
        expected, name = line.split('  ', 1)
        path = (MODULE/name).resolve()
        if not path.is_relative_to((MODULE/'system').resolve()):
            raise ValueError(f'Unexpected payload path: {name}')
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError(f'Payload checksum mismatch: {name}')
        files[name] = data
    if len(files) != 5 or sum(n.endswith('.apk') for n in files) != 3:
        raise ValueError('Expected 3 APKs and 2 permission allowlists')
    for path in sorted(MODULE.glob('*.sh')):
        files[path.name] = path.read_bytes().replace(b'\r\n', b'\n')
    files['module.prop'] = (MODULE/'module.prop').read_bytes().replace(b'\r\n', b'\n')
    for name in ('phh_common.sh', 'phh_health.sh', 'phh_status.sh', 'phh_watchdog.sh',
                 'test_cc_injection.sh'):
        files['tools/'+name] = (REPO/'code/diagnostics'/name).read_bytes().replace(b'\r\n', b'\n')
    files['README.md'] = (REPO/'docs/module-internals.md').read_bytes().replace(b'\r\n', b'\n')
    files['maintenance.md'] = (REPO/'docs/maintenance.md').read_bytes().replace(b'\r\n', b'\n')
    files['LICENSE'] = (REPO/'LICENSE').read_bytes()
    files['floss-ims-local.patch'] = (REPO/'code/patches/floss-ims-local.patch').read_bytes()
    files['SHA256SUMS'] = ''.join(
        f'{hashlib.sha256(data).hexdigest()}  {name}\n' for name, data in sorted(files.items())
    ).encode()
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=MODULE/'vowifi-stack-v7.zip')
    args = parser.parse_args()
    files = payload()  # Validate every input before opening the output.
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_name(args.output.name+'.tmp')
    with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(name, date_time=(2026, 9, 13, 0, 0, 0))
            info.create_system = 3
            info.external_attr = (0o100755 if name.endswith('.sh') else 0o100644) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, data, compresslevel=9)
    with zipfile.ZipFile(temporary) as z:
        if z.testzip() is not None or set(z.namelist()) != set(files):
            raise ValueError('ZIP verification failed')
    temporary.replace(args.output)
    print(f'{args.output} ({args.output.stat().st_size} bytes)')
    print('SHA256 '+hashlib.sha256(args.output.read_bytes()).hexdigest())


if __name__ == '__main__':
    main()
