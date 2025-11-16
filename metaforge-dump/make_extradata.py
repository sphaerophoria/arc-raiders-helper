#!/usr/bin/env python3
import json

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

def main():
    out = []

    with open("preprocessed.json") as f:
        data = json.load(f)

    for item in data:
        print(item["id"])


        out.append({
            "id": item["id"],
            "wiki_link": nameToURL(item["id"]),
            "scraps_into": None
        })

    with open("extradata.json", "w") as f:
        json.dump(out, f, indent=2)

if __name__ == '__main__':
    main()
