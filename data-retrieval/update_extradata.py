#!/usr/bin/env python3
import sys
import json
from pathlib import Path

def nameToURL(name):
    next_capital = True
    ret = ""
    for c in name:
        if next_capital:
            ret += c.upper()
            next_capital = False
        elif c == '-':
            ret += '_'
            next_capital = True
        else:
            ret += c
    return f"https://arcraiders.wiki/wiki/{ret}"

def main(metadata_cache_path, extradata_path):

    metadata_cache_path = Path(metadata_cache_path)

    with open(extradata_path) as f:
        existing_extradata = json.load(f)

    existing_ids = set()
    for item in existing_extradata:
        existing_ids.add(item["id"])

    new_ids = []

    for p in metadata_cache_path.glob("*.json"):
        with open(p) as f:
            metadata = json.load(f)

        for item in metadata["data"]:
            if item["id"] not in existing_ids:
                new_ids.append(item["id"])

    for item in new_ids:
        existing_extradata.append({
            "id": item["id"],
            "wiki_link": nameToURL(item["id"]),
            "scraps_into": None
        })

    with open(extradata_path, "w") as f:
        json.dump(existing_extradata, f, indent=2)

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
