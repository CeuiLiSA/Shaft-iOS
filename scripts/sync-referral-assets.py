#!/usr/bin/env python3
"""Regenerate the iOS referral catalog and native paths from the Android source.
Requires fonttools (`python -m pip install fonttools`). No screenshots or raster UI.
"""
from pathlib import Path
import argparse, json, re, shutil, xml.etree.ElementTree as ET
from fontTools.svgLib.path import parse_path
from fontTools.pens.recordingPen import RecordingPen

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--android', type=Path, default=root.parent / 'Pixiv-Shaft')
parser.add_argument('--check', action='store_true', help='Verify source parity without changing files')
args = parser.parse_args()
android = args.android
output = root / 'Shaft-iOS/Referral'
output.mkdir(parents=True, exist_ok=True)
def write_or_check(path, content):
    if args.check:
        assert path.read_bytes() == content, f'Asset drift: {path}'
    else:
        path.write_bytes(content)
locales = {'zh-Hans':'values','zh-Hant':'values-zh-rTW','en':'values-en','ja':'values-ja','ko':'values-ko','ru':'values-ru','tr':'values-tr'}
catalog = {}
for tag, folder in locales.items():
    elements = ET.parse(android / 'app/src/main/res' / folder / 'strings_referral.xml').getroot()
    catalog[tag] = {item.attrib['name'].removeprefix('referral_'): ''.join(item.itertext()).replace(r'\n', '\n').replace(r"\'", "'").replace(r'\"', '"') for item in elements if item.tag == 'string'}
write_or_check(output / 'referral-strings.json', (json.dumps(catalog, ensure_ascii=False, indent=2) + '\n').encode())
for name in ['regular','medium','semi_bold','bold','extra_bold']:
    write_or_check(root / f'Shaft-iOS/Common/montserrat_{name}.ttf', (android / f'witstudio/src/main/res/font/montserrat_{name}.ttf').read_bytes())
source = (android / 'app/src/main/java/ceui/pixiv/ui/referral/ReferralUi.kt').read_text()
paths = re.findall(r'^    ([A-Z]+)\("([MLAQCZ0-9., \-]+)"\)', source, re.M)
assert len(paths) == 11, paths
lines = ['// Generated from Android ReferralIcon. Run scripts/sync-referral-assets.py.', 'import SwiftUI', '', 'enum ReferralGlyph {', '    case ' + ', '.join(name.lower() for name, _ in paths), '    var path: Path {', '        var p = Path()', '        switch self {']
def point(p):
    return f'CGPoint(x: {p[0]:.9g}, y: {p[1]:.9g})'
for name, raw in paths:
    pen = RecordingPen()
    parse_path(raw, pen)
    lines += [f'        case .{name.lower()}:']
    for op, coords in pen.value:
        if op == 'moveTo': line = f'p.move(to: {point(coords[0])})'
        elif op == 'lineTo': line = f'p.addLine(to: {point(coords[0])})'
        elif op == 'curveTo': line = f'p.addCurve(to: {point(coords[2])}, control1: {point(coords[0])}, control2: {point(coords[1])})'
        elif op == 'qCurveTo': line = f'p.addQuadCurve(to: {point(coords[1])}, control: {point(coords[0])})'
        elif op == 'closePath': line = 'p.closeSubpath()'
        elif op == 'endPath': continue
        else: raise ValueError(op)
        lines += ['            ' + line]
lines += ['        }', '        return p', '    }', '}', '', '''struct ReferralIcon {
    var glyph: ReferralGlyph
    func stroke(_ color: Color, lineWidth: CGFloat) -> some View {
        stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }
    func stroke(_ color: Color, style: StrokeStyle) -> some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 24, y: size.height / 24)
            context.stroke(glyph.path, with: .color(color), style: style)
        }.accessibilityHidden(true)
    }
}''']
write_or_check(output / 'ReferralIcons.swift', ('\n'.join(lines) + '\n').encode())
print(f'{"Verified" if args.check else "Synced"} {len(paths)} icons, {len(catalog)} languages, 5 font weights.')
