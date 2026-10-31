"""Validate the WebGL-free embedded family map.

Extract inline JS for Node syntax validation; never fetch map tiles or 2GIS data.
"""
import ast
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
tree = ast.parse(source)
values = [
    ast.literal_eval(node.value)
    for node in tree.body
    if isinstance(node, ast.Assign)
    and any(isinstance(target, ast.Name) and target.id == "INDEX_HTML" for target in node.targets)
]
assert len(values) == 1
html = values[0]
assert "leaflet" not in html.lower()
assert "maplibre" not in html.lower()
assert "unpkg.com" not in html
assert '"https://tile.openstreetmap.org/"' in html
assert "https://www.openstreetmap.org/copyright" in html
assert 'function project(' in html and 'function unproject(' in html
assert 'function fit(' in html
assert 'addEventListener("pointermove"' in html
assert 'addEventListener("wheel"' in html
assert "© OpenStreetMap contributors" in html
assert 'fetch("api/locations"' in html
assert "10000" in html
assert "markerLayer.appendChild(el)" in html
assert "redraw();" in html
assert "item.label.textContent = label" in html, "Untrusted display names must not become HTML"

inline_scripts = re.findall(r"<script(?:\s[^>]*)?>(.*?)</script>", html, flags=re.DOTALL)
inline_scripts = [code for code in inline_scripts if code.strip()]
assert len(inline_scripts) == 1, "Expected one inline JavaScript block"
pathlib.Path(sys.argv[2]).write_text(inline_scripts[0], encoding="utf-8")
print("Map HTML checks passed; JavaScript extracted for syntax check.")
