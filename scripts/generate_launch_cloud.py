"""Derive a rendering mask from the approved Skivu artwork; keep it unchanged."""
import json
from pathlib import Path
from PIL import Image

root = Path(__file__).resolve().parents[1]
original = Image.open(root / 'assets/branding/skivu-approved.png').convert('RGBA')
image = original.resize((320, 320), Image.Resampling.LANCZOS)
pixels = []
for r, g, b, a in image.getdata():
    pixels.append((255, 255, 255, round((.2126*r + .7152*g + .0722*b) * a / 255)))
image.putdata(pixels)
image.save(root / 'assets/branding/skivu-cloud-mask.png', optimize=True)
points = [(x/320, y/320) for y in range(4,316,5) for x in range(4,316,5)
          if image.getpixel((x,y))[3] > 180]
sample = [points[i*len(points)//420] for i in range(420)]
(root / 'assets/branding/skivu-cloud-particles.json').write_text(
    json.dumps(sample, separators=(',', ':')) + '\n', encoding='utf-8')
print('Generated transparent cloud mask and 420 launch targets.')
