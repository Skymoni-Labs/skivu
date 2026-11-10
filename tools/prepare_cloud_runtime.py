"""Stage the APK-pinned runtime, bundled or downloaded on first use.

Download-mode source builds need only the committed lock file. An available
local archive is still checked; embedded builds require the complete archive.
No network request or package installation is performed by this build tool.
"""
import argparse
import hashlib
import json
import shutil
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--abi', choices=['arm64-v8a', 'x86_64'], required=True)
    parser.add_argument('--source', type=Path, default=Path('E:/zzz/skivu-dsh-engine-20261107/app/runtime-assets'))
    parser.add_argument('--delivery', choices=['embedded', 'download'], default='embedded')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    metadata = json.loads((root / 'tools/cloud-runtime-lock.json').read_text(encoding='utf8'))['runtimes'][args.abi]
    digest = metadata['sha256']
    source = args.source / args.abi
    binary = source / 'runtime.bin'
    if (source / 'runtime.json').exists():
        original = json.loads((source / 'runtime.json').read_text(encoding='utf8'))
        assert all(metadata.get(k) == v for k, v in original.items()), 'Runtime metadata differs from the committed lock'
    if binary.exists():
        with binary.open('rb') as stream:
            actual = hashlib.file_digest(stream, 'sha256').hexdigest()
        assert actual == digest and binary.stat().st_size == metadata['size'], 'Runtime archive differs from the committed lock'
    elif args.delivery == 'embedded':
        raise FileNotFoundError('Embedded builds require the pinned runtime archive: ' + str(binary))
    stage = root / 'android/app/cloud-assets/cloud-runtime'
    stage.mkdir(parents=True, exist_ok=True)
    allowed = (root / 'android/app/cloud-assets').resolve()
    for other in stage.iterdir():
        assert other.resolve().is_relative_to(allowed)
        if other.is_dir() and other.name in ['arm64-v8a', 'x86_64'] and other.name != args.abi:
            shutil.rmtree(other)
    destination = stage / args.abi
    destination.mkdir(exist_ok=True)
    (destination / 'runtime.json').write_text(json.dumps(metadata, indent=2), encoding='utf8')
    if args.delivery == 'embedded':
        shutil.copyfile(binary, destination / 'runtime.bin')
    elif (destination / 'runtime.bin').exists():
        (destination / 'runtime.bin').unlink()
    print(json.dumps({'abi': args.abi, 'sha256': digest, 'bytes': metadata['size'], 'embedded': args.delivery == 'embedded'}))


if __name__ == '__main__':
    main()
