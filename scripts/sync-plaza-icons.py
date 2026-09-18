#!/usr/bin/env python3
from pathlib import Path
import xml.etree.ElementTree as ET
import sys
from fontTools.svgLib.path import parse_path
from fontTools.pens.recordingPen import RecordingPen
root=Path(__file__).resolve().parents[1]
android=(Path(sys.argv[1]) if len(sys.argv)>1 else root.parent/'Pixiv-Shaft')/'app/src/main/res'
if not android.is_dir(): raise SystemExit('Usage: sync-plaza-icons.py /path/to/Pixiv-Shaft')
icons={'heart':'ic_like_heart_outline','heartFilled':'ic_like_heart_fill','comment':'ic_baseline_comment_24','emoji':'chat_ic_emoji','send':'chat_ic_send','more':'ic_more_vert_black_24dp','add':'ic_add_black_24dp','close':'ic_close_black_24dp','chevron':'ic_v3_chevron_24','community':'ic_plaza_feed_24','error':'ic_feed_error'}
lines=['// Generated from Android vector paths; see scripts/sync-plaza-icons.py.','import SwiftUI','','enum PlazaGlyph {','    case '+', '.join(icons),'    var path: Path {','        var p = Path()','        switch self {']
def pt(p): return f'CGPoint(x: {(p[0]+tx)*sx:.9g}, y: {(p[1]+ty)*sy:.9g})'
for name,file in icons.items():
    lines += [f'        case .{name}:']
    source = android/'drawable'/f'{file}.xml'
    if not source.exists(): source = android.parents[3]/'feeds/src/main/res/drawable'/f'{file}.xml'
    tree=ET.parse(source).getroot(); ns='{http://schemas.android.com/apk/res/android}'
    sx=24/float(tree.get(ns+'viewportWidth','24')); sy=24/float(tree.get(ns+'viewportHeight','24'))
    group=next(iter(tree.iter('group')),None)
    tx=float(group.get(ns+'translateX','0')) if group is not None else 0
    ty=float(group.get(ns+'translateY','0')) if group is not None else 0
    for e in tree.iter('path'):
        pen=RecordingPen(); parse_path(e.attrib['{http://schemas.android.com/apk/res/android}pathData'],pen)
        for op,coords in pen.value:
            if op=='moveTo': s=f'p.move(to: {pt(coords[0])})'
            elif op=='lineTo': s=f'p.addLine(to: {pt(coords[0])})'
            elif op=='curveTo': s=f'p.addCurve(to: {pt(coords[2])}, control1: {pt(coords[0])}, control2: {pt(coords[1])})'
            elif op=='qCurveTo': s=f'p.addQuadCurve(to: {pt(coords[1])}, control: {pt(coords[0])})'
            elif op=='closePath': s='p.closeSubpath()'
            elif op=='endPath': continue
            else: raise ValueError(op)
            lines += ['            '+s]
lines += ['        }','        return p','    }','}','', '''struct PlazaIcon: View {
    var glyph: PlazaGlyph
    var size: CGFloat = 24
    var body: some View {
        Canvas { context, bounds in
            context.scaleBy(x: bounds.width / 24, y: bounds.height / 24)
            if glyph == .error {
                context.stroke(glyph.path, with: .foreground, style: StrokeStyle(lineWidth: 0.6, lineCap: .round, lineJoin: .round))
            } else { context.fill(glyph.path, with: .foreground) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}''']
(root/'Shaft-iOS/Plaza/PlazaIcons.swift').write_text('\n'.join(lines)+'\n')
