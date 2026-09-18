#!/usr/bin/env python3
"""Add only Plaza build entries. Preserves every unrelated project byte."""
from pathlib import Path
import hashlib,re,os,tempfile
root=Path(__file__).resolve().parents[1]
p=root/'Shaft-iOS.xcodeproj/project.pbxproj';original=p.read_bytes();s=original.decode()
def ident(kind,path): return hashlib.sha256(('plaza-ios:'+kind+':'+path).encode()).hexdigest()[:24].upper()
def after(marker,line):
    global s
    assert s.count(marker)==1,(marker,s.count(marker));s=s.replace(marker,marker+line,1)
for file in sorted((root/'Shaft-iOS/Plaza').glob('*')):
    if file.suffix not in ['.swift','.json','.xcassets']: continue
    rel='Plaza/'+file.name;fid=ident('file',rel);bid=ident('build',rel)
    if fid in s: continue
    source=file.suffix=='.swift';kind='sourcecode.swift' if source else 'text.json' if file.suffix=='.json' else 'folder.assetcatalog'
    after('/* Begin PBXFileReference section */\n',f'\t\t{fid} /* {file.name} */ = {{isa = PBXFileReference; lastKnownFileType = {kind}; path = "{rel}"; sourceTree = "<group>"; }};\n')
    after('/* Begin PBXBuildFile section */\n',f'\t\t{bid} /* {file.name} in {"Sources" if source else "Resources"} */ = {{isa = PBXBuildFile; fileRef = {fid}; }};\n')
    anchor=re.search(r'A1000000000000000000G002 /\* Shaft-iOS \*/ = \{\s*isa = PBXGroup;\s*children = \(\n',s)
    assert anchor
    after(anchor.group(),f'\t\t\t\t{fid} /* {file.name} */,\n')
    phase='PBXSourcesBuildPhase' if source else 'PBXResourcesBuildPhase'
    match=re.search(r'/\* Begin '+phase+r' section \*/\s*[^\n]+\{\s*isa = '+phase+r';\s*buildActionMask = [^;]+;\s*files = \(\n',s)
    assert match,phase
    after(match.group(),f'\t\t\t\t{bid} /* {file.name} */,\n')
for file in sorted([*(root/'Shaft-iOSTests').glob('Plaza*'), *(root/'Shaft-iOSUITests').glob('Plaza*.swift')]):
    ui=file.parent.name=='Shaft-iOSUITests'
    rel=file.relative_to(root).as_posix();fid=ident('file',rel);bid=ident('build',rel)
    if fid in s: continue
    source=file.suffix=='.swift';kind='sourcecode.swift' if source else 'folder'
    after('/* Begin PBXFileReference section */\n',f'\t\t{fid} /* {file.name} */ = {{isa = PBXFileReference; lastKnownFileType = {kind}; path = "{rel}"; sourceTree = "<group>"; }};\n')
    after('/* Begin PBXBuildFile section */\n',f'\t\t{bid} /* {file.name} */ = {{isa = PBXBuildFile; fileRef = {fid}; }};\n')
    anchor=re.search(r'A1000000000000000000G001 = \{\s*isa = PBXGroup;\s*children = \(\n',s)
    after(anchor.group(),f'\t\t\t\t{fid} /* {file.name} */,\n')
    phaseID='2D339A82CA9C4D373BA23634' if ui else '715CEB466C368648489445F5' if source else 'B27815D00228916F461D5CBD'
    match=re.search(phaseID+r' = \{isa = [^;]+; buildActionMask = [^;]+; files = \(',s)
    assert match,phaseID
    after(match.group(),bid+',')
if p.read_bytes()!=original:
    raise SystemExit('Project changed concurrently; retry against its latest contents.')
with tempfile.NamedTemporaryFile(dir=p.parent,delete=False) as output:
    output.write(s.encode()); pending=Path(output.name)
try:
    if p.read_bytes()!=original: raise SystemExit('Project changed concurrently; retry.')
    os.chmod(pending,p.stat().st_mode)
    os.replace(pending,p)
finally:
    pending.unlink(missing_ok=True)
