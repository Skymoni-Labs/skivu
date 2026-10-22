"""Pin license evidence and verify cached Dart package source against pub.dev archives.

This reads the shared cache but never patches it. Archives stay on D:.
The engine notice is an SDK-wide aggregate, not a claim every entry is linked.
"""
import concurrent.futures
import hashlib
import io
import json
from pathlib import Path
import re
import tarfile
from urllib.request import urlopen
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parents[1]
OUT = Path('D:/CodexBuilds/ski-independent-ui/license-evidence')
OUT.mkdir(parents=True, exist_ok=True)
graph = json.loads((ROOT / '.dart_tool/package_graph.json').read_text(encoding='utf-8'))
packages = {package['name']: package for package in graph['packages']}
RUNTIME = set()
pending = list(packages['ski']['dependencies'])
while pending:
    name = pending.pop()
    if name not in RUNTIME:
        RUNTIME.add(name)
        pending.extend(packages[name]['dependencies'])
lock_text = (ROOT / 'pubspec.lock').read_text(encoding='utf-8')
locks = {}
for name, content in re.findall(r'^  (\w+):\n(.*?)(?=^  \w+:|^sdks:)', lock_text, re.M | re.S):
    version = re.search(r'version: "([^"]+)"', content)
    sha = re.search(r'sha256: "?([a-f0-9]{64})', content)
    locks[name] = {'version': version[1] if version else 'sdk', 'sha256': sha[1] if sha else None}

config = json.loads((ROOT / '.dart_tool/package_config.json').read_text())

def audit(package):
    name = package['name']
    if name == 'ski':
        return None
    root = Path(unquote(urlparse(package['rootUri']).path).lstrip('/'))
    license_path = root / 'LICENSE'
    if not license_path.exists() and name in ('flutter_test', 'flutter_web_plugins'):
        license_path = root.parents[1] / 'LICENSE'
    if not license_path.exists():
        raise ValueError(f'Missing license: {name}')
    text = license_path.read_text(encoding='utf-8')
    identifier = ('SDK aggregate; see engine notices' if name == 'sky_engine' else
                  'Apache-2.0' if 'Apache License' in text[:100] else
                  'BSD-3-Clause' if 'Redistribution and use in source and binary forms' in text else
                  'MIT' if 'Permission is hereby granted, free of charge' in text and 'THE SOFTWARE IS PROVIDED "AS IS"' in text else 'REVIEW')
    if identifier == 'REVIEW':
        raise ValueError(f'Unrecognized license for {name}')
    record = {'name': name, **locks[name], 'scope': 'runtime' if name in RUNTIME else 'development/test only', 'license': identifier, 'license_sha256': hashlib.sha256(text.encode()).hexdigest()}
    if locks[name]['sha256']:
        meta_url = f'https://pub.dev/api/packages/{name}/versions/{locks[name]["version"]}'
        metadata_path = OUT / f'{name}.json'
        metadata = json.loads(metadata_path.read_text()) if metadata_path.exists() else None
        if not metadata or metadata.get('archive_sha256') != locks[name]['sha256']:
            with urlopen(meta_url, timeout=60) as response:
                metadata = json.load(response)
            metadata_path.write_text(json.dumps(metadata, indent=2), encoding='utf-8')
        if metadata['archive_sha256'] != locks[name]['sha256']:
            raise ValueError(f'Lock hash mismatch: {name}')
        archive_path = OUT / f'{name}-{locks[name]["version"]}.tar.gz'
        archive = archive_path.read_bytes() if archive_path.exists() else b''
        if hashlib.sha256(archive).hexdigest() != locks[name]['sha256']:
            with urlopen(metadata['archive_url'], timeout=60) as response:
                archive = response.read()
        if hashlib.sha256(archive).hexdigest() != locks[name]['sha256']:
            raise ValueError(f'Archive hash mismatch: {name}')
        archive_path.write_bytes(archive)
        count = 0
        with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
            for member in tar.getmembers():
                if not member.isfile():
                    continue
                path = member.name.removeprefix('./')
                if not (path.startswith(('lib/', 'android/', 'ios/', 'macos/', 'windows/', 'linux/', 'src/', 'hook/')) or path in ('LICENSE', 'NOTICE', 'pubspec.yaml')):
                    continue
                installed = root / path
                original = tar.extractfile(member).read()
                if not installed.exists() or installed.read_bytes() != original:
                    raise ValueError(f'Cached file differs from official archive: {name}/{path}')
                count += 1
        record.update(source=metadata['pubspec'].get('repository', metadata['pubspec'].get('homepage', meta_url)), archive_url=metadata['archive_url'], verified_files=count, cache_matches_official_archive=True)
    else:
        record.update(source='https://github.com/flutter/flutter/tree/00b0c91f06209d9e4a41f71b7a512d6eb3b9c694', engine='42d3d75a56efe1a2e9902f52dc8006099c45d937')
    destination = ROOT / 'licenses' / 'packages' / name
    destination.mkdir(parents=True, exist_ok=True)
    (destination / 'LICENSE').write_text(text, encoding='utf-8')
    for path in root.glob('NOTICE*'):
        if path.is_file():
            (destination / path.name).write_bytes(path.read_bytes())
    return record

with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
    records = [r for r in pool.map(audit, config['packages']) if r]

manifest = {'framework': {'version': '3.41.9', 'revision': '00b0c91f06209d9e4a41f71b7a512d6eb3b9c694', 'engine_revision': '42d3d75a56efe1a2e9902f52dc8006099c45d937', 'dart': '3.11.5'}, 'packages': records,
 'assets': [{'name': 'Noto Sans SC', 'version': '2.004-H2', 'license': 'OFL-1.1', 'source': 'https://github.com/google/fonts/tree/47d54ca1ebb14fd864695f1d39dc734f39017c33/ofl/notosanssc', 'sha256': hashlib.sha256((ROOT/'assets/fonts/NotoSansSC.ttf').read_bytes()).hexdigest()}, {'name': 'Material Icons SDK font', 'license': 'CC-BY-4.0', 'source': 'official Flutter engine material_fonts artifact', 'modification': 'Flutter build subsets font; original notices retained'}],
 'engine_scope': 'Official SDK aggregate notices retained verbatim. Native wallpaper storage uses dart:io. MPL-2.0 entry is fallback_root_certificates (native Dart IO). FreeType used under FTL alternative. No business code copied into covered SDK files.',
 'status': 'Pinned Pub package archives and cache checks passed, including native platform source folders; exact license texts retained. Runtime scope follows the resolved dependency graph; platform-specific implementations are selected by each build. This is not a complete audit of every native Maven artifact or future dependency.'}
(ROOT/'dependency-audit.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
print(f'Verified {len(records)} packages; {sum(bool(r.get("verified_files")) for r in records)} official archives. No shared-cache mutations.')
