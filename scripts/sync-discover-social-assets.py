#!/usr/bin/env python3
"""Copy the seven Android discovery-entry translations without hand edits."""
import argparse
import json
from pathlib import Path
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser()
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
resources = root.parent / 'Pixiv-Shaft/app/src/main/res'
locales = {'zh-Hans': 'values', 'zh-Hant': 'values-zh-rTW', 'en': 'values-en',
           'ja': 'values-ja', 'ko': 'values-ko', 'ru': 'values-ru', 'tr': 'values-tr'}
catalog = {}
for tag, folder in locales.items():
    entries = {node.attrib['name']: ''.join(node.itertext()) for node in ET.parse(resources / folder / 'strings_discover_social.xml').getroot() if node.tag == 'string'}
    for file in (resources / folder).glob('strings*.xml'):
        for node in ET.parse(file).getroot():
            if node.tag == 'string' and node.attrib.get('name') in ('chat_drawer_entry', 'plaza_title'):
                entries[node.attrib['name']] = ''.join(node.itertext())
    assert len(entries) == 8, (tag, entries)
    catalog[tag] = entries
destination = root / 'Shaft-iOS/Discover/discover-social-strings.json'
data = (json.dumps(catalog, ensure_ascii=False, indent=2) + '\n').encode()
if args.check:
    assert destination.read_bytes() == data, f'{destination} differs from Android'
    print('Verified discovery-entry translations in 7 languages.')
else:
    destination.write_bytes(data)
