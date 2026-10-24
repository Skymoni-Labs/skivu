"""Rasterize the six original art() SVGs without changing their composition.

Requires local Node, Pillow and Chrome/Edge. Uses only a fresh temporary browser
profile and a static local document; no original UI scripts or remote assets run.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
KEYS = ("coast", "flowers", "clouds", "coffee", "mountain", "sunset")
SIDE = 600


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def browser_path(explicit: str | None) -> Path:
    candidates = [explicit] if explicit else [
        "C:/Program Files/Google/Chrome/Application/chrome.exe",
        "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
        shutil.which("google-chrome"), shutil.which("chromium"),
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return Path(candidate)
    raise RuntimeError("A local Chrome or Edge executable is required")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browser")
    parser.add_argument("--preview", type=Path,
                        default=Path("D:/CodexBuilds/ski-independent-ui/license-evidence/social-art-preview.png"))
    args = parser.parse_args()
    source = ROOT / "legacy/social_ui/social.js"
    source_bytes = source.read_bytes()
    source_text = source_bytes.decode("utf-8")
    match = re.search(r"  function art\(key\) \{.*?\n  \}", source_text, re.S)
    if match is None:
        raise RuntimeError("Original art(key) function was not found")
    function = match.group(0).strip()
    # This VM receives only the extracted pure art function. It has no Node
    # process/require, filesystem or DOM APIs, and each invocation is bounded.
    node = r"""
const vm = require('node:vm');
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', part => input += part);
process.stdin.on('end', () => {
  const {source, keys} = JSON.parse(input);
  const result = Object.fromEntries(keys.map(key => [key,
    vm.runInNewContext('(' + source + ')(' + JSON.stringify(key) + ')',
      Object.create(null), {timeout: 1000,
        contextCodeGeneration: {strings: false, wasm: false}})]));
  process.stdout.write(JSON.stringify(result));
});
"""
    response = subprocess.run(
        [shutil.which("node") or "node", "-e", node],
        input=json.dumps({"source": function, "keys": KEYS}),
        text=True, encoding="utf-8", capture_output=True, check=True,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    svgs = json.loads(response.stdout)
    target = ROOT / "assets/social_native"
    target.mkdir(parents=True, exist_ok=True)
    for key, svg in svgs.items():
        # Validate the complete output before opening it in a renderer.
        element = ET.fromstring(svg)
        if element.tag != "svg" or element.attrib.get("viewBox") != "0 0 200 200":
            raise RuntimeError(f"Unexpected SVG root for {key}")
        for child in element.iter():
            if child.tag not in {"svg", "rect", "circle", "ellipse", "path", "g"}:
                raise RuntimeError(f"Unexpected SVG element for {key}")
            if any(name.lower().startswith("on") or name in {"href", "src"}
                   or "url(" in value for name, value in child.attrib.items()):
                raise RuntimeError(f"External or active SVG content for {key}")
        # Only standalone-document metadata is added. Paths, colors, geometry,
        # opacity and the original viewBox are kept exactly as art() returned.
        svgs[key] = svg.replace("<svg ",
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIDE}" height="{SIDE}" ', 1)
        (target / f"{key}.svg").write_text(svgs[key] + "\n", encoding="utf-8")

    browser = browser_path(args.browser)
    # Windows Chrome does not provide a reliable console --version command.
    # Read installation metadata without starting a normal browser session.
    versions = sorted((p.name for p in browser.parent.iterdir()
                       if p.is_dir() and re.fullmatch(r"\d+(?:\.\d+){3}", p.name)),
                      key=lambda value: tuple(map(int, value.split('.'))))
    with tempfile.TemporaryDirectory(prefix="skivu-social-art-") as temporary:
        temporary = Path(temporary)
        html = temporary / "art.html"
        html.write_text(
            '<!doctype html><meta charset="utf-8">'
            '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'">'
            '<style>html,body{margin:0;width:1800px;height:1200px;overflow:hidden}'
            'body{display:grid;grid-template-columns:repeat(3,600px);grid-template-rows:repeat(2,600px)}'
            'svg{display:block;width:600px;height:600px}</style>'
            + "".join(svgs[key] for key in KEYS), encoding="utf-8")
        screenshot = temporary / "art.png"
        command = [str(browser), "--headless", "--disable-gpu",
                   "--disable-background-networking", "--disable-component-update",
                   "--disable-default-apps", "--disable-extensions", "--no-first-run",
                   "--no-default-browser-check", "--hide-scrollbars",
                   "--force-device-scale-factor=1", "--window-size=1800,1200",
                   "--no-proxy-server", "--host-resolver-rules=MAP * ~NOTFOUND",
                   f"--user-data-dir={temporary / 'profile'}",
                   f"--screenshot={screenshot}", html.as_uri()]
        rendered = subprocess.run(command, capture_output=True, timeout=45,
                                  creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        if rendered.returncode != 0 or not screenshot.is_file():
            raise RuntimeError("Offline SVG renderer failed")
        with Image.open(screenshot) as atlas:
            if atlas.size != (SIDE * 3, SIDE * 2):
                raise RuntimeError(f"Unexpected render dimensions: {atlas.size}")
            atlas = atlas.convert("RGB")
            for index, key in enumerate(KEYS):
                x, y = (index % 3) * SIDE, (index // 3) * SIDE
                atlas.crop((x, y, x + SIDE, y + SIDE)).save(
                    target / f"{key}.png", format="PNG", optimize=True)

    records = []
    for key in KEYS:
        png, svg = target / f"{key}.png", target / f"{key}.svg"
        with Image.open(png) as image:
            if image.size != (SIDE, SIDE) or image.getextrema()[0][0] == image.getextrema()[0][1]:
                raise RuntimeError(f"Invalid/blank output: {key}")
        records.append({"key": key, "width": SIDE, "height": SIDE,
                        "png": png.name, "png_bytes": png.stat().st_size,
                        "png_sha256": digest(png.read_bytes()), "svg": svg.name,
                        "svg_sha256": digest(svg.read_bytes()),
                        "original_svg_markup_sha256": digest(
                            json.loads(response.stdout)[key].encode("utf-8"))})
    provenance = {
        "schema": "skivu-original-social-art-v1", "generated": "2026-10-24",
        "source": "legacy/social_ui/social.js::art(key)",
        "source_sha256": digest(source_bytes),
        "source_function_sha256": digest(function.encode("utf-8")),
        "lineage": "Skivu approved original social HTML preview, sourceCommit 2c29740; see legacy/social_ui/PROVENANCE.json",
        "license": "GPL-3.0-only", "copyright": "Copyright (C) 2026 skyjjgw",
        "license_reference": "../../LICENSE", "copyright_reference": "../../COPYRIGHT",
        "renderer": {"kind": "Local Chromium SVG rendering; 3x2 static atlas then lossless PNG crop",
                     "installed_version_directories": versions,
                     "browser_executable_sha256": digest(browser.read_bytes()),
                     "view_box": [0, 0, 200, 200], "output_scale": 3,
                     "network": "Disabled: static local document, no active/external SVG content, CSP default-src none, resolver blocked",
                     "changes": "Only xmlns/width/height were added for standalone SVG. Original paths, shapes, colors, opacity and transforms are unchanged. No AI generation or redrawing."},
        "assets": records,
    }
    (target / "provenance.json").write_text(
        json.dumps(provenance, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    preview = Image.new("RGB", (900, 660), "#ffffff")
    draw = ImageDraw.Draw(preview)
    for index, key in enumerate(KEYS):
        x, y = (index % 3) * 300, (index // 3) * 330
        with Image.open(target / f"{key}.png") as image:
            preview.paste(image.resize((300, 300), Image.Resampling.LANCZOS), (x, y))
        draw.text((x + 12, y + 307), key, fill="#222222")
    args.preview.parent.mkdir(parents=True, exist_ok=True)
    preview.save(args.preview)
    for record in records:
        print(f"{record['key']}: {SIDE}x{SIDE}, {record['png_bytes']} bytes, SHA-256 {record['png_sha256']}")
    print(f"Preview: {args.preview.resolve()}")


if __name__ == "__main__":
    main()
