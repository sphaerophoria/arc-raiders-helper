#!/usr/bin/env python3

from pathlib import Path
import json

def main():
    metaforge_files = Path("downloaded")

    out = []

    for p in metaforge_files.glob("*.json"):
        with p.open("r") as f:
            data = json.load(f)

        for item in data["data"]:
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
            })

    with open("preprocessed.json", "w") as f:
        json.dump(out, f, indent=2)

    pass

if __name__ == '__main__':
    main()
