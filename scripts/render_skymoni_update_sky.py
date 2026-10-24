# SPDX-License-Identifier: AGPL-3.0-only
# Adapted from Skymoni SiteVoidBackdrop, commit
# 6424caee779b19d72f1aa636fed086d4b1b38c92. See docs/update-sky-provenance.md.
"""Render the website's quiet first frame for the native update page.

Requires numpy and Pillow. No network, downloads, random assets or app data.
The generated PNG is artwork, not an embedded copy of this generator.
"""
from pathlib import Path
import math
import numpy as np
from PIL import Image, ImageDraw


def render():
    width, height = 412, 916
    pixels = (1080, 2400)
    layer_width = round(width * .6)
    layer_height = round(layer_width * height / width)
    v, u = np.mgrid[:layer_height, :layer_width]
    u, v = u / layer_width, v / layer_height

    def hashed(x, y):
        value = np.sin(x * 127.1 + y * 311.7 + 81.29) * 43758.5453
        return value - np.floor(value)

    def noise(x, y):
        ix, iy = np.floor(x), np.floor(y)
        fx, fy = x - ix, y - iy
        sx, sy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
        a, b = hashed(ix, iy), hashed(ix + 1, iy)
        c, d = hashed(ix, iy + 1), hashed(ix + 1, iy + 1)
        return a + (b - a) * sx + (c - a) * sy + (a - b - c + d) * sx * sy

    cloud, frequency, amplitude = np.zeros_like(u), 3, .55
    for _ in range(5):
        cloud += noise(u * frequency, v * frequency) * amplitude
        frequency *= 2.1
        amplitude *= .5
    ridge = v - (.8 - u * .58 + np.sin(u * 5) * .06)
    dust = np.exp(-(ridge * ridge) / .035) * cloud ** 2.6
    veil = np.exp(-((u - .55) ** 2 + (v - .45) ** 2) * 2.5)
    tint = (np.sin(u * 4 + v * 2) + 1) / 2
    rgb = np.stack((4 + veil * 3 + dust * (22 + tint * 12),
                    7 + veil * 5 + dust * (49 - tint * 9),
                    16 + veil * 9 + dust * 88), axis=-1)
    nebula = Image.fromarray(np.rint(rgb).clip(0, 255).astype('uint8'))
    # Website drawImage at t=0: driftX=0, driftY=6; 24px overscan.
    sky = nebula.transform(pixels, Image.Transform.EXTENT,
        (24 / (width + 48) * layer_width, 18 / (height + 48) * layer_height,
         (width + 24) / (width + 48) * layer_width,
         (height + 18) / (height + 48) * layer_height),
        Image.Resampling.BILINEAR).convert('RGBA')
    scale = pixels[0] / width
    seed = 8129

    def random():
        nonlocal seed
        seed = (seed * 1664525 + 1013904223) & 0xffffffff
        return seed / 4294967296

    yy, xx = np.mgrid[:pixels[1], :pixels[0]]
    for _ in range(round(width * height / 3400)):
        x = random()
        band = .8 - x * .58 + math.sin(x * 5) * .06
        y = band + (random() + random() - 1) * .19 if random() < .38 else random()
        radius = .3 + random() ** 4 * 1.4
        alpha = .22 + random() * .55
        phase = random() * math.pi * 2
        random()  # depth is used by the website's motion, not this still frame.
        warm = random() > .84
        x = (x * (width + 40) - 20) * scale
        y = (y * height + math.sin(phase) * 7) * scale
        opacity = alpha * .8
        if radius > 1.1:
            halo = np.maximum(0, 1 - np.hypot(xx - x, yy - y) / (radius * 5 * scale))
            layer = np.zeros((pixels[1], pixels[0], 4), dtype='uint8')
            layer[:, :, :3] = (160, 200, 255)
            layer[:, :, 3] = np.rint(halo * 101 * opacity).astype('uint8')
            sky = Image.alpha_composite(sky, Image.fromarray(layer))
        layer = Image.new('RGBA', pixels)
        draw = ImageDraw.Draw(layer)
        r = radius * scale
        color = (234, 223, 207) if warm else (202, 223, 248)
        draw.ellipse((x - r, y - r, x + r, y + r), fill=(*color, round(opacity * 255)))
        if radius > 1.5:
            color = (213, 231, 255, round(opacity * .35 * 255))
            draw.line((x - 4 * scale, y, x + 4 * scale, y), fill=color, width=1)
            draw.line((x, y - 4 * scale, x, y + 4 * scale), fill=color, width=1)
        sky = Image.alpha_composite(sky, layer)
    target = Path(__file__).resolve().parents[1] / 'assets/branding/skymoni-night-sky.png'
    sky.convert('RGB').save(target, optimize=True)
    print(f'{target.name}: {pixels[0]} x {pixels[1]}, {target.stat().st_size} bytes')


if __name__ == '__main__':
    render()
