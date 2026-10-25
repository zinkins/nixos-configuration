"""Validate the embedded family map is library-independent of Leaflet.

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
assert "leaflet" not in html.lower(), "Map must no longer load or call Leaflet"
assert html.count("maplibre-gl@6.10.0/dist/maplibre-gl.css") == 1
assert html.count("maplibre-gl@6.10.0/dist/maplibre-gl.js") == 1
assert "https://tile.openstreetmap.org/{z}/{x}/{y}.png" in html
assert "© OpenStreetMap contributors" in html
assert 'fetch("api/locations"' in html
assert "10000" in html
assert "new maplibregl.Marker" in html
assert "map.fitBounds" in html
assert "new maplibregl.NavigationControl" in html
assert "item.label.textContent = label" in html, "Untrusted display names must not become HTML"

inline_scripts = re.findall(r"<script(?:\\s[^>]*)?>(.*?)</script>", html, flags=re.DOTALL)
inline_scripts = [code for code in inline_scripts if code.strip()]
assert len(inline_scripts) == 1, "Expected one inline JavaScript block"
pathlib.Path(sys.argv[2]).write_text(inline_scripts[0], encoding="utf-8")
print("Map HTML checks passed; JavaScript extracted for syntax check.")
