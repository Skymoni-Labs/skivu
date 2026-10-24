"""Preserve the project's original 24px SVG icons as native Flutter paths.

Build-time authoring utility only; requires fontTools. No runtime SVG/JS engine.
"""
from pathlib import Path
import re, json, xml.etree.ElementTree as ET
from fontTools.svgLib.path import parse_path
from fontTools.pens.recordingPen import RecordingPen

root = Path(__file__).resolve().parents[1]
legacy = root / 'legacy/social_ui'
html = (legacy / 'index.html').read_text(encoding='utf-8')
base = re.search(r'const ICONS=\{(.*?)\};', html, re.S).group(1)
icons = {a or b: c for a,b,c in re.findall(r"(?:'([^']+)'|([\w-]+))\s*:\s*'([^']*)'", base)}
for name in ['social.js','social_features.js','qq_chat.js','chat_interactions.js','companion_ui.js']:
    text = (legacy/name).read_text(encoding='utf-8')
    for a,b,c in re.findall(r"ICONS(?:\.([\w-]+)|\['([^']+)'\])\s*=\s*'([^']*)'", text):
        icons[a or b] = c
icons.update({
    'chevron-left':'<path d="m15 6-6 6 6 6"/>',
    'play':'<path d="m8 4 12 8-12 8Z"/>',
    'pause':'<path d="M8 4v16M16 4v16"/>',
    'envelope':'<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 6 9 7 9-7"/>',
    'transfer':'<path d="M3 8h18m-5-5 5 5-5 5M21 16H3m5-5-5 5 5 5"/>',
})
icons['chevron-right'] = icons['right']
def n(v):
    value = round(float(v), 7)
    return str(int(value)) if value.is_integer() else str(value)
def args(points):return ', '.join(n(v) for p in points for v in p)
def path_code(node):
    tag=node.tag;a=node.attrib
    if tag=='path':
        pen=RecordingPen();parse_path(a['d'],pen);out='Path()'
        for cmd,points in pen.value:
            if cmd=='moveTo':out+='..moveTo('+args(points)+')'
            elif cmd=='lineTo':out+='..lineTo('+args(points)+')'
            elif cmd=='curveTo':out+='..cubicTo('+args(points)+')'
            elif cmd=='qCurveTo':
                assert len(points)==2
                out+='..quadraticBezierTo('+args(points)+')'
            elif cmd=='closePath':out+='..close()'
            elif cmd!='endPath':raise ValueError(cmd)
        return out
    if tag in ['circle','ellipse']:
        rx=a.get('rx',a.get('r'));ry=a.get('ry',a.get('r'))
        return 'Path()..addOval(Rect.fromCenter(center: Offset('+n(a['cx'])+', '+n(a['cy'])+'), width: '+n(float(rx)*2)+', height: '+n(float(ry)*2)+'))'
    if tag=='rect':
        rect='Rect.fromLTWH('+', '.join(n(a.get(k,0)) for k in ['x','y','width','height'])+')'
        return 'Path()..addRRect(RRect.fromRectAndRadius('+rect+', Radius.circular('+n(a.get('rx',0))+')))'
    raise ValueError(tag)
rows=[]
for name,svg in icons.items():
    nodes=ET.fromstring('<svg>'+svg+'</svg>')
    rows.append('  '+json.dumps(name)+': [')
    for node in nodes:
        rows.append('    _SocialStroke('+path_code(node)+', '+n(node.get('stroke-width','1.8'))+'),')
    rows.append('  ],')
target=root/'lib/native_social_icons.dart'
target.write_text('''// Generated from the project's preserved SVG icon definitions.
// Regenerate: python tool/generate_native_social_icons.py
import 'package:flutter/material.dart';

class NativeSocialIcon extends StatelessWidget {
  const NativeSocialIcon(this.name, {super.key, this.size = 24, this.color, this.filled = false, this.strokeWidth});
  final String name;
  final double size;
  final Color? color;
  final bool filled;
  final double? strokeWidth;
  static List<String> get names => _socialPaths.keys.toList(growable: false);
  @override
  Widget build(BuildContext context) => SizedBox.square(dimension: size,
    child: CustomPaint(painter: _SocialIconPainter(name,
      color ?? IconTheme.of(context).color ?? const Color(0xff191919), filled, strokeWidth)));
}
class _SocialStroke {
  _SocialStroke(this.path, this.width);
  final Path path;
  final double width;
}
class _SocialIconPainter extends CustomPainter {
  _SocialIconPainter(this.name, this.color, this.filled, this.strokeWidth);
  final String name;
  final Color color;
  final bool filled;
  final double? strokeWidth;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();canvas.scale(size.width / 24, size.height / 24);
    for (final stroke in _socialPaths[name] ?? _socialPaths['chat']!) {
      if (filled) canvas.drawPath(stroke.path, Paint()..color = color..style = PaintingStyle.fill);
      canvas.drawPath(stroke.path, Paint()..color = color
        ..style = PaintingStyle.stroke..strokeWidth = strokeWidth ?? stroke.width
        ..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round);
    }
    canvas.restore();
  }
  @override
  bool shouldRepaint(_SocialIconPainter old) => old.name != name || old.color != color || old.filled != filled || old.strokeWidth != strokeWidth;
}
final _socialPaths = <String, List<_SocialStroke>>{
'''+ '\n'.join(rows) +'\n};\n', encoding='utf-8')
print(json.dumps({'native_icons':len(icons),'path':str(target)}))
