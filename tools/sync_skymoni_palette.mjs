// Run with Node's --experimental-strip-types and an explicit Skymoni source.
import {readFile, writeFile, copyFile} from 'node:fs/promises';
import {resolve, dirname} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';

const source = process.argv[2];
if (!source) throw new Error('Pass the Skymoni mobile source directory.');
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const paletteFile = resolve(source, 'src/data/palettes.ts');
const {colorThemes, getPalette} = await import(pathToFileURL(paletteFile));
const roles = ['background', 'surface', 'soft', 'ink', 'muted', 'line', 'accent', 'tint', 'button', 'onButton', 'glassStrong', 'glassSoft', 'glassRim', 'onAccent', 'solidButton', 'onSolidButton', 'secondary', 'secondarySoft', 'onSecondary'];
const argb = css => {
  if (!/^#[0-9a-f]{6}([0-9a-f]{2})?$/i.test(css)) throw new Error(`Invalid color ${css}`);
  const rgb = css.slice(1, 7), alpha = css.slice(7) || 'ff';
  return `0x${alpha}${rgb}`.toLowerCase();
};
const output = [
  "import 'package:flutter/material.dart';",
  '',
  '// Generated from Skymoni mobile palettes and Radix Colors 3.0.0.',
  '// See docs/skymoni-palette-provenance.json and licenses/RadixColors-MIT.txt.',
  'class SkymoniPalette {',
  '  const SkymoniPalette(this._colors);',
  '  final List<int> _colors;',
  ...roles.map((role, i) => `  Color get ${role} => Color(_colors[${i}]);`),
  '}',
  '',
  'const skymoniThemeNames = <String, String>{',
  ...colorThemes.map(t => `  '${t.id}': '${t.name}',`),
  '};',
  '',
  'SkymoniPalette skymoniPalette(String id, {required bool dark, bool starry = false}) =>',
  "    _palettes[id]![starry ? 2 : dark ? 1 : 0];",
  '',
  'const _palettes = <String, List<SkymoniPalette>>{',
];
for (const theme of colorThemes) {
  output.push(`  '${theme.id}': [`);
  for (const [dark, starry] of [[false, false], [true, false], [true, true]]) {
    const p = getPalette(theme.id, dark, starry);
    output.push('    SkymoniPalette([' + roles.map(role => argb(p[role])).join(', ') + ']),');
  }
  output.push('  ],');
}
output.push('};', '');
await writeFile(resolve(root, 'lib/skymoni_palette.dart'), output.join('\n'));
await copyFile(resolve(source, 'node_modules/@radix-ui/colors/LICENSE'), resolve(root, 'licenses/RadixColors-MIT.txt'));
await writeFile(resolve(root, 'docs/skymoni-palette-provenance.json'), JSON.stringify({
  source: 'Skymoni mobile src/data/palettes.ts',
  sourceSha256: createHash('sha256').update(await readFile(paletteFile)).digest('hex'),
  radixColorsVersion: '3.0.0',
  roles,
  variants: ['light', 'dark', 'starry'],
  themes: colorThemes.map(t => t.id),
}, null, 2) + '\n');
