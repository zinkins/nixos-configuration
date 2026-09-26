{ pkgs, ... }:

let
  familyLocationPort = 8085;
  python = pkgs.python3.withPackages (ps: with ps; [ requests websockets ]);

  familyLocationApp = pkgs.writeText "family-location.py" ''
    import asyncio
    import json
    import logging
    import math
    import os
    import threading
    import time
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from urllib.parse import urlparse

    import requests
    import websockets

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    log = logging.getLogger("family-location")

    PORT = ${toString familyLocationPort}
    WS_BASE = "wss://zond.api.2gis.ru/api/1.1/user/ws"
    LOGIN_URL = "https://id.2gis.com/api/v1/sign_in"
    APP_VERSION = "6.31.0"
    CHANNELS = "markers,sharing,routes"
    ORIGIN = "https://2gis.kz"
    USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/124 Safari/537.36"
    STALE_MS = 24 * 60 * 60 * 1000

    lock = threading.Lock()
    profiles = {}
    states = {}
    connected = False
    last_error = ""
    account_uid = ""
    account_name = ""

    def configured():
        return bool(os.environ.get("DGIS_EMAIL") and os.environ.get("DGIS_PASSWORD"))

    def wanted_friend_names():
        raw = os.environ.get("FAMILY_LOCATION_NAMES", "")
        return {item.strip() for item in raw.split("|") if item.strip()}

    def login():
        global account_uid, account_name
        response = requests.post(
            LOGIN_URL,
            json={
                "grant_type": "password",
                "username": os.environ["DGIS_EMAIL"],
                "password": os.environ["DGIS_PASSWORD"],
                "locale": "ru",
            },
            headers={
                "Content-Type": "application/json",
                "Origin": "https://id.2gis.com",
                "User-Agent": USER_AGENT,
            },
            timeout=20,
        )
        response.raise_for_status()
        access_token = response.cookies.get("id_access_token")
        if not access_token:
            raise RuntimeError("2GIS login succeeded but no access token was returned")

        payload = response.json()
        uid = payload.get("id") or payload.get("uid") or payload.get("user_id") or ""
        name = payload.get("display_name") or payload.get("name") or ""
        with lock:
            account_uid = str(uid) if uid else ""
            account_name = str(name) if name else ""
        return access_token

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

    INDEX_HTML = r"""<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Геолокация</title>
  <style>
    html, body { height: 100%; margin: 0; overflow: hidden; background: #07101d; color: #fff; font-family: system-ui, sans-serif; }
    #map { position: relative; width: 100%; height: 100%; overflow: hidden; background: #101827; }
    #tiles, #markers { position: absolute; inset: 0; overflow: hidden; }
    .tile { position: absolute; width: 256px; height: 256px; user-select: none; pointer-events: none; }
    .marker { position: absolute; transform: translate(-50%, -100%); min-width: 34px; height: 34px; border-radius: 18px 18px 18px 4px; background: #2563eb; border: 2px solid #dbeafe; box-shadow: 0 2px 12px rgba(0,0,0,.65); display: grid; place-items: center; font-weight: 700; font-size: 12px; cursor: default; }
    .marker.self { background: #059669; border-color: #d1fae5; }
    .marker.stale { background: #475569; border-color: #cbd5e1; }
    .label { position: absolute; transform: translate(-50%, 8px); white-space: nowrap; padding: 3px 7px; border-radius: 6px; background: rgba(2,6,23,.88); border: 1px solid rgba(148,163,184,.45); font-size: 12px; box-shadow: 0 2px 8px rgba(0,0,0,.45); }
    #status { position: absolute; z-index: 10; top: 8px; left: 8px; right: 8px; display: flex; gap: 6px; flex-wrap: wrap; pointer-events: none; }
    .pill { padding: 5px 8px; border-radius: 999px; background: rgba(2,6,23,.88); border: 1px solid rgba(148,163,184,.45); font-size: 12px; box-shadow: 0 2px 8px rgba(0,0,0,.35); }
    .ok { border-color: rgba(52,211,153,.65); }
    .warn { border-color: rgba(251,191,36,.7); }
    .bad { border-color: rgba(248,113,113,.7); }
    #empty { position: absolute; z-index: 5; inset: 0; display: none; place-items: center; text-align: center; padding: 24px; color: #cbd5e1; }
    #attribution { position: absolute; z-index: 10; right: 4px; bottom: 3px; padding: 2px 5px; border-radius: 4px; background: rgba(255,255,255,.82); color: #111827; font-size: 10px; }
    #attribution a { color: #1d4ed8; }
  </style>
</head>
<body>
<div id="map">
  <div id="tiles"></div>
  <div id="markers"></div>
  <div id="status"></div>
  <div id="empty"></div>
  <div id="attribution">© <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noreferrer">OpenStreetMap</a></div>
</div>
<script>
(function () {
  var TILE = 256;
  var statusEl = document.getElementById("status");
  var tilesEl = document.getElementById("tiles");
  var markersEl = document.getElementById("markers");
  var emptyEl = document.getElementById("empty");

  function worldSize(z) { return TILE * Math.pow(2, z); }
  function lonX(lon, z) { return (lon + 180) / 360 * worldSize(z); }
  function latY(lat, z) {
    var clipped = Math.max(-85.05112878, Math.min(85.05112878, lat));
    var sin = Math.sin(clipped * Math.PI / 180);
    return (0.5 - Math.log((1 + sin) / (1 - sin)) / (4 * Math.PI)) * worldSize(z);
  }
  function initials(name) {
    var parts = String(name || "?").trim().split(/\s+/).filter(Boolean);
    if (!parts.length) return "?";
    return parts.slice(0, 2).map(function (part) { return part.charAt(0).toUpperCase(); }).join("");
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
  function chooseView(points, width, height) {
    if (points.length === 1) {
      return { z: 15, x: lonX(points[0].lon, 15), y: latY(points[0].lat, 15) };
    }
    for (var z = 16; z >= 2; z--) {
      var xs = points.map(function (p) { return lonX(p.lon, z); });
      var ys = points.map(function (p) { return latY(p.lat, z); });
      var spanX = Math.max.apply(null, xs) - Math.min.apply(null, xs);
      var spanY = Math.max.apply(null, ys) - Math.min.apply(null, ys);
      if (spanX <= Math.max(1, width - 120) && spanY <= Math.max(1, height - 120)) {
        return {
          z: z,
          x: (Math.max.apply(null, xs) + Math.min.apply(null, xs)) / 2,
          y: (Math.max.apply(null, ys) + Math.min.apply(null, ys)) / 2
        };
      }
    }
    return { z: 2, x: lonX(0, 2), y: latY(0, 2) };
  }
  function renderTiles(view, width, height) {
    tilesEl.replaceChildren();
    var n = Math.pow(2, view.z);
    var left = view.x - width / 2;
    var top = view.y - height / 2;
    var minTx = Math.floor(left / TILE) - 1;
    var maxTx = Math.floor((left + width) / TILE) + 1;
    var minTy = Math.max(0, Math.floor(top / TILE) - 1);
    var maxTy = Math.min(n - 1, Math.floor((top + height) / TILE) + 1);

    for (var ty = minTy; ty <= maxTy; ty++) {
      for (var tx = minTx; tx <= maxTx; tx++) {
        var wrappedX = ((tx % n) + n) % n;
        var img = document.createElement("img");
        img.className = "tile";
        img.alt = "";
        img.draggable = false;
        img.src = "https://tile.openstreetmap.org/" + view.z + "/" + wrappedX + "/" + ty + ".png";
        img.style.left = (tx * TILE - left) + "px";
        img.style.top = (ty * TILE - top) + "px";
        tilesEl.appendChild(img);
      }
    }
  }
  function renderMarkers(people, view, width, height) {
    markersEl.replaceChildren();
    var left = view.x - width / 2;
    var top = view.y - height / 2;

    people.forEach(function (person) {
      var px = lonX(person.lon, view.z) - left;
      var py = latY(person.lat, view.z) - top;
      var marker = document.createElement("div");
      marker.className = "marker" + (person.isSelf ? " self" : "") + (person.available ? "" : " stale");
      marker.style.left = px + "px";
      marker.style.top = py + "px";
      marker.textContent = initials(person.name);
      var details = person.name + " · " + ageText(person.lastSeen);
      if (person.battery != null) details += " · батарея " + person.battery + "%";
      if (person.accuracy != null) details += " · ±" + Math.round(person.accuracy) + " м";
      marker.title = details;
      markersEl.appendChild(marker);

      var label = document.createElement("div");
      label.className = "label";
      label.style.left = px + "px";
      label.style.top = py + "px";
      label.textContent = person.name + " · " + ageText(person.lastSeen) + (person.battery != null ? " · " + person.battery + "%" : "");
      markersEl.appendChild(label);
    });
  }
  function pill(text, cls) {
    var el = document.createElement("span");
    el.className = "pill " + cls;
    el.textContent = text;
    return el;
  }
  function renderStatus(data) {
    statusEl.replaceChildren();
    if (!data.configured) {
      statusEl.appendChild(pill("2ГИС: требуется настройка", "bad"));
      return;
    }
    statusEl.appendChild(pill(data.connected ? "2ГИС: подключен" : "2ГИС: переподключение", data.connected ? "ok" : "warn"));
    if (!data.selfSeen) statusEl.appendChild(pill("Своя позиция пока не пришла из 2ГИС", "warn"));
    if (data.missing && data.missing.length) statusEl.appendChild(pill("Нет данных: " + data.missing.join(", "), "warn"));
  }
  function render(data) {
    renderStatus(data);
    var people = (data.people || []).filter(function (p) { return p.lat != null && p.lon != null; });
    if (!people.length) {
      tilesEl.replaceChildren();
      markersEl.replaceChildren();
      emptyEl.style.display = "grid";
      emptyEl.textContent = data.configured ? "Ждём координаты выбранных людей от 2ГИС" : "Добавьте локальный credentials.env для подключения к 2ГИС";
      return;
    }
    emptyEl.style.display = "none";
    var width = document.getElementById("map").clientWidth;
    var height = document.getElementById("map").clientHeight;
    var view = chooseView(people, width, height);
    renderTiles(view, width, height);
    renderMarkers(people, view, width, height);
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
  window.addEventListener("resize", refresh);
})();
</script>
</body>
</html>
"""

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
        access_token = None

        while True:
            if not configured():
                with lock:
                    connected = False
                    last_error = "credentials are not configured"
                await asyncio.sleep(30)
                continue

            try:
                if not access_token:
                    access_token = await asyncio.to_thread(login)

                url = (
                    WS_BASE
                    + "?appVersion=" + APP_VERSION
                    + "&channels=" + CHANNELS
                    + "&token=" + access_token
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
                if getattr(exc, "code", None) in (4001, 4003, 401):
                    access_token = None
                log.warning("2GIS websocket closed; reconnecting")
            except requests.HTTPError as exc:
                with lock:
                    connected = False
                    last_error = "2GIS authentication failed"
                access_token = None
                log.error("2GIS authentication failed with HTTP status %s", exc.response.status_code if exc.response is not None else "unknown")
            except Exception as exc:
                with lock:
                    connected = False
                    last_error = type(exc).__name__
                access_token = None
                log.warning("2GIS connection error: %s", type(exc).__name__)

            await asyncio.sleep(delay)
            delay = min(delay * 2, 60)

    threading.Thread(target=start_http, name="family-location-http", daemon=True).start()
    asyncio.run(websocket_loop())
  '';
in
{
  users.groups.family-location = { };
  users.users.family-location = {
    isSystemUser = true;
    group = "family-location";
  };

  # Credentials and the friend allow-list are deliberately runtime-only so
  # account data and names never enter the public NixOS repository.
  systemd.tmpfiles.rules = [
    "d /var/lib/family-location 0700 root root - -"
  ];

  systemd.services.family-location = {
    description = "Private 2GIS location feed for family.home";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "simple";
      User = "family-location";
      Group = "family-location";
      EnvironmentFile = "-/var/lib/family-location/credentials.env";
      ExecStart = "${python}/bin/python ${familyLocationApp}";
      Restart = "on-failure";
      RestartSec = 5;

      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
    };
  };

  systemd.services.homepage-dashboard = {
    wants = [ "family-location.service" ];
    after = [ "family-location.service" ];
  };
}
