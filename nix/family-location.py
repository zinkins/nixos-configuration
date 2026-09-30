import asyncio
import base64
import json
import logging
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

import websockets

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("family-location")

PORT = int(os.environ.get("FAMILY_LOCATION_PORT", "8085"))
WS_BASE = "wss://zond.api.2gis.ru/api/1.1/user/ws"
APP_VERSION = "6.31.0"
CHANNELS = "markers,sharing,routes"
ORIGIN = "https://2gis.kz"
STALE_MS = 24 * 60 * 60 * 1000

lock = threading.Lock()
profiles = {}
states = {}
connected = False
last_error = ""
account_uid = ""
account_name = ""


def access_token():
    return os.environ.get("DGIS_ACCESS_TOKEN", "").strip()


def configured():
    return bool(access_token())


def wanted_friend_names():
    raw = os.environ.get("FAMILY_LOCATION_NAMES", "")
    return {item.strip() for item in raw.split("|") if item.strip()}


def decode_token_identity(token):
    global account_uid, account_name
    parts = token.split(".")
    if len(parts) != 3:
        return
    try:
        payload = parts[1] + "=" * (-len(parts[1]) % 4)
        data = json.loads(base64.urlsafe_b64decode(payload.encode("ascii")))
    except Exception:
        return

    uid = data.get("sub") or data.get("id") or data.get("uid") or data.get("user_id") or ""
    name = data.get("name") or data.get("display_name") or ""
    with lock:
        account_uid = str(uid) if uid else ""
        account_name = str(name) if name else ""


def apply_state(item):
    uid = str(item.get("id") or "")
    if not uid:
        return

    location = item.get("location") or {}
    battery = item.get("battery") or {}
    movement = item.get("movement") or {}
    place = item.get("locationPlace") or {}
    place_status = (place.get("status") or {}).get("id")

    with lock:
        previous = states.get(uid, {})
        current = dict(previous)
        current["uid"] = uid
        current["last_seen"] = item.get("lastSeen", previous.get("last_seen", 0))

        if location.get("lat") is not None:
            current["lat"] = location.get("lat")
            current["lon"] = location.get("lon")
            current["accuracy"] = location.get("accuracy")
            current["speed"] = location.get("speed")

        if "level" in battery:
            current["battery"] = round(float(battery["level"]) * 100)
            current["charging"] = bool(battery.get("isCharging"))

        if "status" in movement:
            status = movement.get("status")
            current["movement"] = "no_geo" if status == "noGeo" else status

        if place_status:
            current["place"] = place_status

        states[uid] = current


def handle_initial_state(payload):
    with lock:
        for profile in payload.get("profiles", []):
            uid = str(profile.get("id") or "")
            if not uid:
                continue
            profiles[uid] = {
                "name": profile.get("name") or uid[:8],
                "logo": profile.get("logo"),
            }

    for item in payload.get("states", []):
        apply_state(item)


def handle_message(raw):
    try:
        message = json.loads(raw)
    except json.JSONDecodeError:
        return

    message_type = message.get("type", "")
    payload = message.get("payload", {})

    if message_type == "initialState" and isinstance(payload, dict):
        handle_initial_state(payload)
        return

    items = payload if isinstance(payload, list) else [payload]
    for item in items:
        if not isinstance(item, dict):
            continue
        if item.get("id") and ("location" in item or "lastSeen" in item or message_type == "friendState"):
            apply_state(item)


def public_snapshot():
    now_ms = int(time.time() * 1000)
    selected_names = wanted_friend_names()

    with lock:
        local_profiles = dict(profiles)
        local_states = {uid: dict(value) for uid, value in states.items()}
        self_uid = account_uid
        self_name = account_name
        is_connected = connected
        error = last_error

    people = []
    seen_friend_names = set()
    self_seen = False

    for uid, state in local_states.items():
        profile = local_profiles.get(uid, {})
        profile_name = str(profile.get("name") or "")
        is_self = bool(self_uid and uid == self_uid)

        if not is_self and profile_name not in selected_names:
            continue

        if is_self:
            self_seen = True
        elif profile_name:
            seen_friend_names.add(profile_name)

        last_seen = int(state.get("last_seen") or 0)
        people.append({
            "id": uid,
            "name": "Я" if is_self else profile_name,
            "isSelf": is_self,
            "lat": state.get("lat"),
            "lon": state.get("lon"),
            "accuracy": state.get("accuracy"),
            "speed": state.get("speed"),
            "battery": state.get("battery"),
            "charging": state.get("charging", False),
            "movement": state.get("movement", "unknown"),
            "place": state.get("place", "unknown"),
            "lastSeen": last_seen,
            "available": bool(last_seen and now_ms - last_seen < STALE_MS),
        })

    people.sort(key=lambda person: (not person["isSelf"], person["name"].casefold()))
    missing = sorted(selected_names - seen_friend_names)

    return {
        "configured": configured(),
        "connected": is_connected,
        "error": error,
        "people": people,
        "missing": missing,
        "selfSeen": self_seen,
        "selfName": self_name,
    }


INDEX_HTML = r'''<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Геолокация</title>
  <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" crossorigin="">
  <style>
    html, body, #map { height: 100%; margin: 0; }
    body { background: #07101d; color: #fff; font-family: system-ui, sans-serif; }
    #status { position: absolute; z-index: 1000; top: 8px; left: 8px; right: 8px; display: flex; gap: 6px; flex-wrap: wrap; pointer-events: none; }
    .pill { padding: 5px 8px; border-radius: 999px; background: rgba(2,6,23,.88); border: 1px solid rgba(148,163,184,.45); font-size: 12px; box-shadow: 0 2px 8px rgba(0,0,0,.35); }
    .ok { border-color: rgba(52,211,153,.65); }
    .warn { border-color: rgba(251,191,36,.7); }
    .bad { border-color: rgba(248,113,113,.7); }
  </style>
</head>
<body>
<div id="map"></div>
<div id="status"></div>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js" crossorigin=""></script>
<script>
(function () {
  var map = L.map("map", { zoomControl: true }).setView([55.0084, 82.9357], 11);
  var markers = [];
  var statusEl = document.getElementById("status");

  L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
    maxZoom: 19,
    attribution: "© OpenStreetMap"
  }).addTo(map);

  function pill(text, cls) {
    var el = document.createElement("span");
    el.className = "pill " + cls;
    el.textContent = text;
    return el;
  }

  function ageText(ms) {
    if (!ms) return "нет данных";
    var sec = Math.max(0, Math.floor((Date.now() - ms) / 1000));
    if (sec < 60) return "сейчас";
    var min = Math.floor(sec / 60);
    if (min < 60) return min + " мин назад";
    var hours = Math.floor(min / 60);
    if (hours < 24) return hours + " ч назад";
    return Math.floor(hours / 24) + " дн назад";
  }

  function renderStatus(data) {
    statusEl.replaceChildren();
    if (!data.configured) {
      statusEl.appendChild(pill("2ГИС: требуется DGIS_ACCESS_TOKEN", "bad"));
      return;
    }
    statusEl.appendChild(pill(data.connected ? "2ГИС: подключен" : "2ГИС: переподключение", data.connected ? "ok" : "warn"));
    if (!data.selfSeen) statusEl.appendChild(pill("Своя позиция пока не пришла из 2ГИС", "warn"));
    if (data.missing && data.missing.length) statusEl.appendChild(pill("Нет данных: " + data.missing.join(", "), "warn"));
  }

  function render(data) {
    renderStatus(data);
    markers.forEach(function (marker) { map.removeLayer(marker); });
    markers = [];

    var points = [];
    (data.people || []).forEach(function (person) {
      if (person.lat == null || person.lon == null) return;
      var text = person.name + " · " + ageText(person.lastSeen);
      if (person.battery != null) text += " · батарея " + person.battery + "%";
      var marker = L.marker([person.lat, person.lon]).addTo(map).bindTooltip(text, { permanent: true, direction: "top" });
      markers.push(marker);
      points.push([person.lat, person.lon]);
    });

    if (points.length === 1) map.setView(points[0], 15);
    else if (points.length > 1) map.fitBounds(points, { padding: [40, 40], maxZoom: 15 });
  }

  async function refresh() {
    try {
      var response = await fetch("api/locations", { cache: "no-store" });
      if (!response.ok) throw new Error("HTTP " + response.status);
      render(await response.json());
    } catch (error) {
      statusEl.replaceChildren(pill("Локальный API недоступен", "bad"));
    }
  }

  refresh();
  setInterval(refresh, 10000);
})();
</script>
</body>
</html>
'''


class Handler(BaseHTTPRequestHandler):
    def send_bytes(self, body, content_type):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "SAMEORIGIN")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/", "/index.html"):
            self.send_bytes(INDEX_HTML.encode("utf-8"), "text/html; charset=utf-8")
            return
        if path == "/api/locations":
            body = json.dumps(public_snapshot(), ensure_ascii=False).encode("utf-8")
            self.send_bytes(body, "application/json; charset=utf-8")
            return
        self.send_response(404)
        self.end_headers()

    def log_message(self, fmt, *args):
        return


def start_http():
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


async def websocket_loop():
    global connected, last_error
    delay = 5

    while True:
        token = access_token()
        if not token:
            with lock:
                connected = False
                last_error = "DGIS_ACCESS_TOKEN is not configured"
            await asyncio.sleep(30)
            continue

        decode_token_identity(token)
        try:
            url = (
                WS_BASE
                + "?appVersion=" + APP_VERSION
                + "&channels=" + CHANNELS
                + "&token=" + token
            )
            async with websockets.connect(
                url,
                additional_headers={"Origin": ORIGIN},
                ping_interval=30,
                ping_timeout=10,
                open_timeout=15,
            ) as websocket:
                with lock:
                    connected = True
                    last_error = ""
                log.info("Connected to 2GIS location feed")
                delay = 5

                while True:
                    raw = await asyncio.wait_for(websocket.recv(), timeout=300)
                    handle_message(raw)

        except asyncio.TimeoutError:
            with lock:
                connected = False
                last_error = "2GIS feed became idle"
            log.warning("2GIS feed idle for 300 seconds; reconnecting")
        except websockets.exceptions.ConnectionClosed as exc:
            with lock:
                connected = False
                last_error = "2GIS websocket closed"
            log.warning("2GIS websocket closed (%s); reconnecting", getattr(exc, "code", "unknown"))
        except Exception as exc:
            with lock:
                connected = False
                last_error = type(exc).__name__
            log.warning("2GIS connection error: %s", type(exc).__name__)

        await asyncio.sleep(delay)
        delay = min(delay * 2, 60)


threading.Thread(target=start_http, name="family-location-http", daemon=True).start()
asyncio.run(websocket_loop())
