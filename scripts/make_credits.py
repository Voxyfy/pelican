"""Builds Pelican/Resources/Credits.html from the licenses of the Swift packages in use.

macOS shows Credits.html in the standard About window. Apache 2.0 and MIT both ask that the
license travel with the binary, so run this after adding or updating a package:

    python3 scripts/make_credits.py
"""
import html, json, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
checkouts = root / "build/SourcePackages/checkouts"
resolved = root / "Pelican.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
pins = {p["identity"]: p for p in json.loads(resolved.read_text())["pins"]}

parts = ["<html><body style=\"font: 11px -apple-system; color: #555\">",
         "<p>© 2026 Batuhan Haymana. All rights reserved.</p>",
         "<p>Pelican is built with these open-source libraries. Thank you to their authors.</p>"]
for folder in sorted(checkouts.iterdir(), key=lambda p: p.name.lower()):
    license = next((f for f in folder.iterdir() if f.name.lower().startswith(("license", "copying"))), None)
    if not license:
        continue
    pin = pins.get(folder.name.lower(), {})
    version = pin.get("state", {}).get("version", "")
    url = pin.get("location", "")
    parts.append(f"<h4 style=\"margin-bottom:2px\">{html.escape(folder.name)} {html.escape(version)}</h4>")
    if url:
        parts.append(f"<p style=\"margin-top:0\"><a href=\"{html.escape(url)}\">{html.escape(url)}</a></p>")
    parts.append(f"<pre style=\"white-space:pre-wrap; font: 10px Menlo\">{html.escape(license.read_text(errors='replace'))}</pre>")
    # Apache 2.0 section 4(d): NOTICE files travel with the binary too.
    notice = next((f for f in folder.iterdir() if f.name.lower().startswith("notice")), None)
    if notice:
        parts.append(f"<pre style=\"white-space:pre-wrap; font: 10px Menlo\">{html.escape(notice.read_text(errors='replace'))}</pre>")
parts.append("</body></html>")
out = root / "Pelican/Resources/Credits.html"
out.write_text("\n".join(parts))
print(f"{out.relative_to(root)}: {sum(1 for p in parts if p.startswith('<h4'))} packages")
