#!/usr/bin/env python3
"""Sync the seven shared sticker translations from Pixiv-Shaft."""
from pathlib import Path
import json
import sys
import xml.etree.ElementTree as ET

source = Path(sys.argv[1]) / "app/src/main/res"
target = Path(__file__).resolve().parents[1] / "Shaft-iOS/Sticker/sticker-strings.json"
languages = {
    "values": "zh-Hans", "values-zh-rTW": "zh-Hant", "values-en": "en",
    "values-ja": "ja", "values-ko": "ko", "values-ru": "ru", "values-tr": "tr",
}
catalog = {}
for folder, tag in languages.items():
    catalog[tag] = {
        item.attrib["name"]: "".join(item.itertext()).replace("\\'", "'")
        for item in ET.parse(source / folder / "sticker_strings.xml").getroot()
        if item.tag == "string"
    }
target.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
