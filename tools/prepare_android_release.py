"""Prepare release-only generated Android registration for offline Gradle builds."""
import json
import re
from pathlib import Path

import yaml

root = Path(__file__).resolve().parents[1]
manifest = yaml.safe_load((root / 'pubspec.yaml').read_text(encoding='utf8'))
version, code = manifest['version'].split('+', 1)
plugins = json.loads((root / '.flutter-plugins-dependencies').read_text(encoding='utf8'))
registrant = root / 'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java'
text = registrant.read_text(encoding='utf8')
original_classes = re.findall(r'new ([\w.]+)\(', text)
removed = []
for plugin in plugins['plugins'].get('android', []):
    if not plugin.get('dev_dependency') and plugin['name'] not in manifest.get('dev_dependencies', {}):
        continue
    pubspec = yaml.safe_load((Path(plugin['path']) / 'pubspec.yaml').read_text(encoding='utf8'))
    android = pubspec.get('flutter', {}).get('plugin', {}).get('platforms', {}).get('android', {})
    if not android.get('pluginClass'):
        continue
    name = android['package'] + '.' + android['pluginClass']
    assert re.fullmatch(r'[A-Za-z0-9_.$]+', name)
    if name not in text:
        continue
    pattern = r'    try \{\s*flutterEngine\.getPlugins\(\)\.add\(new ' + re.escape(name) + r'\(\)\);\s*\} catch \(Exception e\) \{[^}]*\}\s*'
    text, count = re.subn(pattern, '', text)
    assert count == 1 and name not in text, 'Unexpected generated registration format'
    removed.append(name)
assert sorted(re.findall(r'new ([\w.]+)\(', text)) == sorted(x for x in original_classes if x not in removed)
registrant.write_text(text, encoding='utf8')
properties = root / 'android/local.properties'
lines = properties.read_text(encoding='utf8').splitlines() if properties.exists() else []
replace = {'sdk.dir': 'E:/DevTools/Android/Sdk', 'flutter.sdk': 'E:/DevTools/flutter-operit2-rolelife',
           'flutter.versionName': version, 'flutter.versionCode': code, 'flutter.buildMode': 'release'}
lines = [line for line in lines if line.split('=', 1)[0] not in replace]
properties.write_text('\n'.join(lines + [k + '=' + v for k, v in replace.items()]) + '\n', encoding='utf8')
print(json.dumps({'release_registration_prepared': True, 'dev_plugins_removed': len(removed), 'version': version, 'code': int(code)}))
