"""Resize the approved artwork for packaging; never redraw the original mark.

Development-only dependency: Pillow. Run from any directory with Python 3.
"""
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'assets/branding/skivu-approved.png'
EXPECTED = '1f848fa262277cf53f61963ec7ef99587c1c46cad6c5bcadbf8502c0f6eb12b6'


def main():
    assert hashlib.sha256(SOURCE.read_bytes()).hexdigest() == EXPECTED, 'Approved artwork changed'
    original = Image.open(SOURCE).convert('RGBA')
    assert original.width == original.height
    outputs = {}

    def save(relative, bitmap):
        path = ROOT / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        bitmap.save(path, optimize=True)
        outputs[relative] = {
            'width': bitmap.width,
            'height': bitmap.height,
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
        }

    for density, scale in [('mdpi', 1), ('hdpi', 1.5), ('xhdpi', 2), ('xxhdpi', 3), ('xxxhdpi', 4)]:
        prefix = f'android/app/src/main/res/mipmap-{density}'
        size = round(48 * scale)
        legacy = original.resize((size, size), Image.Resampling.LANCZOS)
        save(f'{prefix}/ic_launcher.png', legacy)
        # Supersampled circular mask for launchers using the legacy round icon.
        mask = Image.new('L', (size * 4, size * 4))
        ImageDraw.Draw(mask).ellipse((0, 0, size * 4 - 1, size * 4 - 1), fill=255)
        rounded = legacy.copy()
        rounded.putalpha(mask.resize((size, size), Image.Resampling.LANCZOS))
        save(f'{prefix}/ic_launcher_round.png', rounded)
        # 108dp adaptive layers; the 72dp source square keeps the cloud itself
        # within Android's central 66dp safe zone, preserving the legacy scale.
        canvas_size, art_size = round(108 * scale), round(72 * scale)
        foreground = Image.new('RGBA', (canvas_size, canvas_size))
        art = original.resize((art_size, art_size), Image.Resampling.LANCZOS)
        inset = (canvas_size - art_size) // 2
        foreground.alpha_composite(art, (inset, inset))
        save(f'{prefix}/ic_launcher_foreground.png', foreground)

    save('web/favicon.png', original.resize((64, 64), Image.Resampling.LANCZOS))
    for size in (192, 512):
        save(f'web/icons/Icon-{size}.png', original.resize((size, size), Image.Resampling.LANCZOS))
    (ROOT / 'branding-assets.json').write_text(json.dumps({
        'name': 'Skivu', 'source': str(SOURCE.relative_to(ROOT)).replace('\\', '/'),
        'source_sha256': EXPECTED, 'generated': outputs,
    }, indent=2) + '\n', encoding='utf-8')
    print(f'Generated {len(outputs)} brand images from the unchanged approved artwork.')


if __name__ == '__main__':
    main()
