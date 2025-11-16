#!/usr/bin/env python3

from pathlib import Path
import json

def fixSalvageInfo(info):
    ret = []
    if info is None:
        return None

    for key, value in info.items():
        ret.append({
            "id": key,
            "quantity": value
        })
    return ret

def checkSalvageInfo(info, all_ids):
    for mapping in info.values():
        if mapping is None:
            continue

        for key in mapping.keys():
            if key not in all_ids:
                raise RuntimeError(f"{key} is not a valid id")

def main():
    metaforge_files = Path("downloaded")
    with open("extradata.json") as f:
        extradata = json.load(f)

    salvage_info = {}
    for item in extradata:
        salvage_info[item["id"]] = item["scraps_into"]

    print(salvage_info["candle-holder"])
    out = []

    all_ids = set()

    for p in metaforge_files.glob("*.json"):
        with p.open("r") as f:
            data = json.load(f)

        for item in data["data"]:
            all_ids.add(item["id"])
            components = []

            for component in item["components"]:
                components.append({
                    "id": component["component"]["id"],
                    "quantity": component["quantity"],
                })

            recycle_components = []
            for component in item["recycle_components"]:
                recycle_components.append({
                    "id": component["component"]["id"],
                    "quantity": component["quantity"],
                })

            rarity = item.get("rarity")
            if rarity is not None:
                rarity = rarity.lower()

            out.append({
                "id": item["id"],
                "item_type": item["item_type"],
                "name": item["name"],
                "rarity": rarity,
                "value": item["value"],
                "components": components,
                "recycle_components": recycle_components,
                "salvage_components": fixSalvageInfo(salvage_info[item["id"]])
            })

    checkSalvageInfo(salvage_info, all_ids)

    with open("preprocessed.json", "w") as f:
        json.dump(out, f, indent=2)

    pass

if __name__ == '__main__':
    main()
