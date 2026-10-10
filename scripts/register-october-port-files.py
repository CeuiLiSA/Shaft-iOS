#!/usr/bin/env python3
"""Register October sources while preserving unrelated project entries."""
from pathlib import Path
import hashlib
import re

root = Path(__file__).resolve().parents[1]
project = root / "Shaft-iOS.xcodeproj/project.pbxproj"
original = project.read_text()
content = original
sources = ["Common/IllustListLayout.swift", "Common/ScrollEdgeFeedback.swift", "More/AppLock.swift", "More/AIExemptAuthors.swift",
           "Download/DownloadNotices.swift", "Download/ImageTransferPolicy.swift", "Localization/OctoberPortStrings.swift"]
sources += [str(p.relative_to(root / "Shaft-iOS")) for p in sorted((root / "Shaft-iOS/Backup").glob("*.swift"))]
tests = [p.name for p in sorted((root / "Shaft-iOSTests").glob("October*.swift"))]

def insert(marker, value):
    global content
    if content.count(marker) != 1:
        raise SystemExit(f"Ambiguous project marker: {marker}")
    content = content.replace(marker, marker + value, 1)

for path, test in [(p, False) for p in sources] + [(p, True) for p in tests]:
    if not (root / ("Shaft-iOSTests" if test else "Shaft-iOS") / path).exists():
        continue
    name = Path(path).name
    rel = f"Shaft-iOSTests/{path}" if test else path
    fid = hashlib.sha256(f"october-port:file:{rel}".encode()).hexdigest()[:24].upper()
    bid = hashlib.sha256(f"october-port:build:{rel}".encode()).hexdigest()[:24].upper()
    if fid in content:
        continue
    insert("/* Begin PBXFileReference section */\n", f'\t\t{fid} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{rel}"; sourceTree = "<group>"; }};\n')
    insert("/* Begin PBXBuildFile section */\n", f"\t\t{bid} /* {name} */ = {{isa = PBXBuildFile; fileRef = {fid}; }};\n")
    group = r"A1000000000000000000G001 = \{" if test else r"A1000000000000000000G002 /\* Shaft-iOS \*/ = \{"
    match = re.search(group + r"\s*isa = PBXGroup;\s*children = \(\n", content)
    if not match:
        raise SystemExit("Missing source group")
    insert(match.group(), f"\t\t\t\t{fid} /* {name} */,\n")
    if test:
        match = re.search(r"715CEB466C368648489445F5 = \{isa = PBXSourcesBuildPhase; buildActionMask = [^;]+; files = \(", content)
        insert(match.group(), bid + ",")
    else:
        match = re.search(r"/\* Begin PBXSourcesBuildPhase section \*/\s*[^\n]+\{\s*isa = PBXSourcesBuildPhase;\s*buildActionMask = [^;]+;\s*files = \(\n", content)
        insert(match.group(), f"\t\t\t\t{bid} /* {name} */,\n")
if project.read_text() != original:
    raise SystemExit("Project changed concurrently; retry.")
project.write_text(content)
