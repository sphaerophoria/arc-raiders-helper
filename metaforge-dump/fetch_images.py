#!/usr/bin/env python3

import urllib.request as request
from pathlib import Path
import json

def main():
    img_path = Path("images")
    img_path.mkdir(exist_ok=True)

    for p in Path("downloaded").glob("*.json"):
        with p.open("r") as f:
            data = json.load(f)
        for item in data["data"]:
            print(item["id"], item["icon"])

            try:
                icon = item["icon"]
                if icon is None:
                    continue

                res = request.urlopen(icon)
                item_id = item["id"]
                with (img_path / f"{item_id}.webp").open("wb") as f:
                    f.write(res.read())
            except Exception as e:
                print("error", e)
                continue


if __name__ == '__main__':
    main()
