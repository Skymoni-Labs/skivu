# Skivu galaxy artwork

The current README header uses matching light and dark galaxy artwork generated for Skivu with the built-in **imagegen** tool on **2026-10-24**. The dark artwork is an edit of the light composition. These are artistic visualizations.

| Theme | Background | Dimensions | Bytes | SHA-256 |
| --- | --- | --- | --- | --- |
| Light | [skivu-galaxy-light.jpg](skivu-galaxy-light.jpg) | 2172 × 724 | 230,832 | `77eb50408e4dc15f33b5a936bc587163856f41843aec1f85cb4cea3edafe54fc` |
| Dark | [skivu-galaxy-dark.jpg](skivu-galaxy-dark.jpg) | 2172 × 724 | 276,854 | `72dce3bf982e5c3c778127b9c4cb336d3e098402748e64bb5948bf65b44dc78e` |

## Header assets

- Chinese: [light](skivu-cover-zh.svg), [dark](skivu-cover-zh-dark.svg).
- English: [light](skivu-cover.svg), [dark](skivu-cover-dark.svg).
- The backgrounds are delivered as optimized JPEGs with their generated framing and dimensions preserved. Each SVG embeds its background and the approved Skivu logo source unchanged. A luminance mask preserves the cloud's original contours while presenting it in matching blue-grey or silver tones without the black launcher tile. The app's launcher assets remain unchanged.
- Transparent edge fades blend the banner into the surrounding page. GitHub's theme-specific image links select the light or dark artwork, including when the account uses a single theme that differs from the system preference.
- Typography is stable. Motion consists of a slow galaxy drift, breathing stars and an occasional meteor; `prefers-reduced-motion` retains the static scene.
- The separate [App icon](skivu-app-icon-rounded.svg) above the language links wraps the original launcher PNG with rounded corners; the source PNG is unchanged.
- Earlier artwork remains available in Git history.

## Light artwork prompt

```text
Use case: ads-marketing. Asset: final background-only hero artwork for Skivu, an elegant personal AI app with translucent glass UI. Generate a wide panoramic 3:1 image, ideally 2304x768 or equivalent. A refined HIGH-KEY LIGHT THEME galaxy background that belongs naturally on a white GitHub page. An identifiable but gently diffused spiral galaxy is positioned entirely in the right half, its small pearlescent center around x=76%, y=46%, soft organic spiral arms made of misty pale silver-blue and restrained lavender interstellar clouds. The galaxy has delicate photographic celestial depth, with softly layered translucent nebular veils, graceful natural dust structures and a few tiny stellar points, yet feels airy and spacious, not visually noisy. LEFT HALF stays essentially clean pure white negative space for dark brand typography added later; a barely visible whisper of ice-blue light may reach the far left bottom. All outside edges, especially the full bottom and left borders, dissolve naturally to pure white #ffffff. The galaxy's palette is soft blue-grey, icy blue, pearl and very pale lilac, with enough local tonal definition to remain recognizable at banner size. Fine-art celestial photography meets quiet sophisticated glass-app branding. The image should feel tactile, atmospheric, editorial and calm. Background art ONLY. No text, letters, logos, UI, cards, frames, hard borders, vector orbit rings, dotted paths, graphical particle spirals, planets, black outer space, bright neon, lens flares, starburst spikes, dense speckled noise or exaggerated brilliant core.
```

## Dark artwork edit prompt

The light artwork is the edit target.

```text
Use case: lighting-weather. Edit target: the attached light-theme galaxy background generated for Skivu. Create its matching DARK-THEME counterpart. Keep the same panoramic 3:1 framing, exact galaxy spiral structure, galaxy center and placement, relative size, calm left-half negative space, and soft photographic cloud textures. Change only the lighting and palette for a GitHub dark page: the surrounding empty sky and all outside edges fade to deep neutral ink #0d1117, the left half stays clean dark negative space for pale text added later. Illuminate the spiral's fine cloud and dust layers gently with muted steel blue, silver and a little restrained lavender; preserve the pearlescent core but lower its intensity, keeping natural shadow detail and generous dark space. Elegant and atmospheric with quiet glass-app sensibility, not a dense wallpaper. Keep photographic depth while making star density subtle. No text, lettering, logos, graphic rings, particle paths, frames, UI, planets, giant flares or saturated neon. Preserve the original aspect ratio and composition.
```
