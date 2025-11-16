#!/usr/bin/env python3

import urllib.request as request
from pathlib import Path
import json

def main():
    out_dir = Path("downloaded")
    out_dir.mkdir(exist_ok=True)

    has_next_page = True
    page_idx = 1
    while has_next_page:
        res = request.urlopen(f"https://metaforge.app/api/arc-raiders/items?page={page_idx}&limit=50&includeComponents=true")
        data = res.read()
        with (out_dir / f"{page_idx}.json").open("wb") as f:
            f.write(data)

        parsed = json.loads(data)
        has_next_page = parsed["pagination"]["hasNextPage"]

        page_idx += 1


if __name__ == '__main__':
    main()
