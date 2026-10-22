"""Retain license evidence beside the local Web preview on every rebuild."""
from pathlib import Path
import hashlib
import json
import shutil

root = Path(__file__).resolve().parents[1]
web = Path('D:/CodexBuilds/ski-independent-ui/build/web')
if not (web / 'main.dart.js').is_file():
    raise SystemExit('Build the Flutter Web application first.')
notices = web / 'third-party'
notices.mkdir(exist_ok=True)
shutil.copytree(root / 'licenses', notices / 'licenses', dirs_exist_ok=True)
for name in ['THIRD_PARTY_NOTICES.md', 'dependency-audit.json', 'ORB-PROVENANCE.txt', 'appearance-font-sources.json']:
    shutil.copy2(root / name, notices / name)
files = {str(p.relative_to(web)).replace('\\', '/'): hashlib.sha256(p.read_bytes()).hexdigest() for p in web.rglob('*') if p.is_file() and p.name != 'release-manifest.json'}
(web / 'release-manifest.json').write_text(json.dumps({'application': 'Skivu', 'version': '0.1.0', 'mode': 'independent-mobile-preview', 'files': files}, indent=2), encoding='utf-8')
print(f'Packaged local preview with notices; {len(files)} files hashed.')
