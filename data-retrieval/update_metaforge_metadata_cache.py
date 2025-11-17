#!/usr/bin/env python3

import urllib.request as request
import shutil
from pathlib import Path
import tempfile
import sys
import json

def main(out_path):
    with tempfile.TemporaryDirectory() as tmpd:
        tmpd = Path(tmpd)

        has_next_page = True
        page_idx = 1
        while has_next_page:
            url = f"https://metaforge.app/api/arc-raiders/items?page={page_idx}&limit=50&includeComponents=true"
            print(f"Reading {url}")
            res = request.urlopen(url)

            data = res.read()
            with (tmpd / f"{page_idx}.json").open("wb") as f:
                f.write(data)

            parsed = json.loads(data)
            has_next_page = parsed["pagination"]["hasNextPage"]

            page_idx += 1

        try:
            shutil.rmtree(out_path)
        except FileNotFoundError:
            pass

        tmpd.rename(out_path)





if __name__ == '__main__':
    main(sys.argv[1])
