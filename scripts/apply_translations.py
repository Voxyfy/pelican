"""Fill the Turkish column of Localizable.xcstrings from translations_tr.json.

Keys that are the same in every language (placeholders like server.com) are
marked "do not translate". Run after `xcstringstool sync` adds new keys.
"""
import json, pathlib, sys

root = pathlib.Path(__file__).resolve().parent.parent
catalog_path = root / "Pelican/Resources/Localizable.xcstrings"
tr = json.loads((root / "scripts/translations_tr.json").read_text())
catalog = json.loads(catalog_path.read_text())
same_everywhere = {"", "server.com", "/www/project", "Pelican — %@", "%@\n\n%@"}

missing = []
for key, entry in catalog["strings"].items():
    if key in same_everywhere:
        entry["shouldTranslate"] = False
        entry.pop("localizations", None)
    elif key in tr:
        entry.setdefault("localizations", {})["tr"] = {
            "stringUnit": {"state": "translated", "value": tr[key]}
        }
    else:
        missing.append(key)

catalog_path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
if missing:
    print("Missing Turkish:", *missing, sep="\n  ")
    sys.exit(1)
print(f"Turkish filled for {len(catalog['strings']) - len(same_everywhere)} strings")
