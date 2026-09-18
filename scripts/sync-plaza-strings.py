#!/usr/bin/env python3
"""Copy Android plaza copy (all seven languages); keep this module isolated."""
import json, pathlib, sys, xml.etree.ElementTree as ET
root=pathlib.Path(__file__).resolve().parents[1]
android=(pathlib.Path(sys.argv[1]) if len(sys.argv)>1 else root.parent/'Pixiv-Shaft')/'app/src/main/res'
if not android.is_dir(): raise SystemExit('Usage: sync-plaza-strings.py /path/to/Pixiv-Shaft')
locales={'zh-Hans':'values','zh-Hant':'values-zh-rTW','en':'values-en','ja':'values-ja','ko':'values-ko','ru':'values-ru','tr':'values-tr'}
result={}
for tag,folder in locales.items():
    catalog={}
    for path in (android/folder).glob('*.xml'):
        for item in ET.parse(path).getroot():
            key=item.get('name','')
            if key.startswith(('plaza_', 'discover_social_', 'discover_community_', 'discover_chat_', 'sticker_')) or key in ['cancel','comments','chat_title']:
                if item.tag=='string':
                    catalog[key]=''.join(item.itertext()).replace(r'\n','\n').replace(r"\'", "'").replace(r'\"','"')
                elif item.tag=='plurals':
                    catalog[key]=''.join(item[-1].itertext())
                elif item.tag=='string-array':
                    for i,entry in enumerate(item): catalog[f'{key}_{i}']=''.join(entry.itertext())
    result[tag]=catalog
(root/'Shaft-iOS/Plaza/plaza-strings.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print('Plaza strings:', {k:len(v) for k,v in result.items()})
