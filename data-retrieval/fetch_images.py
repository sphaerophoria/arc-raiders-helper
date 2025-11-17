#!/usr/bin/env python3

import urllib.request as request
from pathlib import Path
import json
import sys

def main(metadata_path, img_path):
    metadata_path = Path(metadata_path)

    img_path = Path(img_path)
    img_path.mkdir(exist_ok=True)

    for p in Path(metadata_path).glob("*.json"):
        with p.open("r") as f:
            data = json.load(f)

        for item in data["data"]:
            print(item["id"], item["icon"])

            try:
                icon = item["icon"]
                if icon is None:
                    continue

                item_id = item["id"]
                img_out = (img_path / f"{item_id}.webp")
                if img_out.exists():
                    continue

                res = request.urlopen(icon)
                with img_out.open("wb") as f:
                    f.write(res.read())
            except Exception as e:
                print("error", e)
                continue


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
