"""Stage the existing verified DSH Linux payload inside the main APK.

No network/package install, no change to old app data. Run before Flutter build.
The payload source is the audited local runtime tree or --source release assets.
"""
import argparse, hashlib, json, shutil
from pathlib import Path

p=argparse.ArgumentParser();p.add_argument('--abi',choices=['arm64-v8a','x86_64'],required=True);p.add_argument('--source',type=Path,default=Path('E:/zzz/skivu-dsh-engine-20261107/app/runtime-assets'));a=p.parse_args()
root=Path(__file__).resolve().parents[1];source=a.source/a.abi
metadata=json.loads((source/'runtime.json').read_text())
digest=hashlib.file_digest((source/'runtime.bin').open('rb'),'sha256').hexdigest()
assert digest==metadata['sha256'],'Runtime payload hash mismatch'
stage=root/'android/app/cloud-assets/cloud-runtime'
stage.mkdir(parents=True,exist_ok=True)
for other in stage.iterdir():
    assert other.resolve().is_relative_to((root/'android/app/cloud-assets').resolve())
    if other.is_dir() and other.name in ['arm64-v8a','x86_64'] and other.name!=a.abi:
        shutil.rmtree(other)
dest=stage/a.abi;dest.mkdir(exist_ok=True)
for name in ['runtime.bin','runtime.json']:shutil.copyfile(source/name,dest/name)
print(json.dumps({'abi':a.abi,'sha256':digest,'bytes':(dest/'runtime.bin').stat().st_size,'embedded':True}))
