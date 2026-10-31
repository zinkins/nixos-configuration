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



def initial_state_diagnostics(payload):
    """Return only schema flags and counts, never tokens, IDs, names or coordinates."""
    raw_profiles = payload.get("profiles")
    raw_states = payload.get("states")
    source_profiles = raw_profiles if isinstance(raw_profiles, list) else []
    source_states = raw_states if isinstance(raw_states, list) else []
    source_profiles = [p for p in source_profiles if isinstance(p, dict)]
    source_states = [p for p in source_states if isinstance(p, dict)]

    profile_by_id = {
        str(p["id"]): p for p in source_profiles if p.get("id") is not None
    }
    state_by_id = {
        str(state["id"]): state
        for state in source_states if state.get("id") is not None
    }
    with_geo = {
        uid for uid, state in state_by_id.items()
        if isinstance(state.get("location"), dict)
        and state["location"].get("lat") is not None
        and state["location"].get("lon") is not None
    }
    allowed_names = wanted_friend_names()
    self_like_keys = (
        "self", "me", "owner", "account", "user", "myState",
        "selfState", "userState", "currentUser", "currentUserState",
        "myProfile", "userProfile", "currentProfile",
    )
    with lock:
        identity = account_uid

    token = access_token()
    return {
        "tokenFormat": "jwt-like" if len(token.split(".")) == 3 else "opaque",
        "identityClaimDecoded": bool(identity),
        "identityMatchesProfile": bool(identity and identity in profile_by_id),
        "identityMatchesState": bool(identity and identity in state_by_id),
        "profiles": len(profile_by_id),
        "states": len(state_by_id),
        "statesWithCoordinates": len(with_geo),
        "statesWithoutProfile": sum(uid not in profile_by_id for uid in state_by_id),
        "statesWithoutProfileCoordinates": len(with_geo - profile_by_id.keys()),
        "namedProfilesOutsideAllowlistWithCoordinates": sum(
            uid in with_geo and bool(p.get("name"))
            and str(p["name"]) not in allowed_names
            for uid, p in profile_by_id.items()
        ),
        "selfLikePayloadFields": [key for key in self_like_keys if key in payload],
    }


def handle_message(raw):
    try:
        message = json.loads(raw)
    except json.JSONDecodeError:
        return

    message_type = message.get("type", "")
    payload = message.get("payload", {})

    if message_type == "initialState" and isinstance(payload, dict):
        if os.environ.get("FAMILY_LOCATION_DIAGNOSTICS", "") == "1":
            # Log only aggregate counts / known field names; do not log feed payload.
            log.info(
                "2GIS initialState diagnostics: %s",
                json.dumps(initial_state_diagnostics(payload), sort_keys=True),
            )
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
  <!-- OpenStreetMap raster tiles; no WebGL or JavaScript CDN needed. -->
  <style>
    html, body, #map { height: 100%; margin: 0; }
    #map { position: relative; overflow: hidden; cursor: grab; touch-action: none; user-select: none; }
    #map.dragging { cursor: grabbing; }
    .tile-layer, .marker-layer { position: absolute; inset: 0; }
    .tile-layer img { position: absolute; width: 256px; height: 256px; pointer-events: none; user-select: none; }
    .marker-layer, .leader-layer, .label-layer { pointer-events: none; }
    .person-leader { position: absolute; width: 1px; background: rgba(255,255,255,.8); box-shadow: 0 0 2px #020617; }
    #people-controls { position: absolute; z-index: 20; bottom: 20px; left: 8px; right: 55px; display: flex; flex-wrap: wrap; gap: 5px; pointer-events: none; }
    #people-controls button { pointer-events: auto; background: rgba(2,6,23,.92); color: #fff; border: 1px solid #64748b; border-radius: 999px; padding: 5px 10px; font: 12px system-ui, sans-serif; cursor: pointer; }
    #people-controls button[aria-pressed="true"] { border-color: #34d399; background: #064e3b; }
    #people-controls button:focus-visible { outline: 2px solid #fff; outline-offset: 2px; }
    .map-controls { position: absolute; z-index: 15; top: 8px; right: 8px; display: flex; flex-direction: column; border-radius: 6px; overflow: hidden; box-shadow: 0 1px 8px #0008; }
    .map-controls button { border: 0; border-bottom: 1px solid #aaa; padding: 5px 11px; min-width: 34px; background: #fff; color: #111; font: bold 20px system-ui, sans-serif; cursor: pointer; }
    .map-controls button:last-child { border-bottom: 0; }
    .map-attribution { position: absolute; z-index: 15; right: 0; bottom: 0; background: #fffd; padding: 2px 5px; font: 10px system-ui, sans-serif; }
    .map-attribution a { color: #134a76; }
    body { background: #07101d; color: #fff; font-family: system-ui, sans-serif; }
    #status { position: absolute; z-index: 10; top: 8px; left: 8px; right: 56px; display: flex; gap: 6px; flex-wrap: wrap; pointer-events: none; }
    .pill { padding: 5px 8px; border-radius: 999px; background: rgba(2,6,23,.88); border: 1px solid rgba(148,163,184,.45); font-size: 12px; box-shadow: 0 2px 8px rgba(0,0,0,.35); }
    .ok { border-color: rgba(52,211,153,.65); }
    .warn { border-color: rgba(251,191,36,.7); }
    .bad { border-color: rgba(248,113,113,.7); }
    .person-pin { position: absolute; width: 16px; height: 16px; transform: translate(-50%, -50%); pointer-events: none; }
    .person-label {
      background: rgba(2,6,23,.92); border: 1px solid rgba(148,163,184,.6);
      color: #fff; padding: 5px 7px; border-radius: 6px; font: 12px system-ui, sans-serif;
      position: absolute; transform: translateX(-50%); white-space: nowrap;
      box-shadow: 0 2px 8px rgba(0,0,0,.35); max-width: calc(100% - 16px);
      overflow: hidden; text-overflow: ellipsis; box-sizing: border-box;
    }
    .person-dot { box-sizing: border-box; width: 16px; height: 16px; border-radius: 50%; background: #34d399; border: 2px solid #fff; box-shadow: 0 1px 6px #000b; }
  </style>
</head>
<body>
<div id="map"></div>
<div id="status"></div>
<div id="people-controls" aria-label="Показать местоположение человека"></div>
<script>
(function () {
  "use strict";
  var mapEl = document.getElementById("map");
  var statusEl = document.getElementById("status");
  var peopleControlsEl = document.getElementById("people-controls");
  var tileLayer = document.createElement("div");
  var leaderLayer = document.createElement("div");
  var markerLayer = document.createElement("div");
  var labelLayer = document.createElement("div");
  tileLayer.className = "tile-layer";
  leaderLayer.className = "leader-layer";
  markerLayer.className = "marker-layer";
  labelLayer.className = "label-layer";
  mapEl.appendChild(tileLayer);
  mapEl.appendChild(leaderLayer);
  mapEl.appendChild(markerLayer);
  mapEl.appendChild(labelLayer);

  var zoom = 11;
  var center = [82.9357, 55.0084];
  var tiles = new Map();
  var markers = new Map();
  var personButtons = new Map();
  var selectedId = null;
  var fitted = false;
  var tileError = false;
  var dragging = null;
  var maxLat = 85.05112878;
  var tileSize = 256;

  function pill(text, cls) {
    var el = document.createElement("span");
    el.className = "pill " + cls;
    el.textContent = text;
    return el;
  }
  function clamp(value, lo, hi) {
    return Math.max(lo, Math.min(hi, value));
  }
  function project(lon, lat, level) {
    var radians = clamp(lat, -maxLat, maxLat) * Math.PI / 180;
    var world = tileSize * Math.pow(2, level);
    return [
      (lon + 180) / 360 * world,
      (1 - Math.log(Math.tan(radians) + 1 / Math.cos(radians)) / Math.PI) / 2 * world
    ];
  }
  function unproject(x, y, level) {
    var world = tileSize * Math.pow(2, level);
    var nx = ((x % world) + world) % world;
    var ny = clamp(y, 0, world);
    return [
      nx / world * 360 - 180,
      Math.atan(Math.sinh(Math.PI * (1 - 2 * ny / world))) * 180 / Math.PI
    ];
  }
  function redraw() {
    var width = mapEl.clientWidth;
    var height = mapEl.clientHeight;
    if (!width || !height) return;
    var cp = project(center[0], center[1], zoom);
    var left = cp[0] - width / 2;
    var top = cp[1] - height / 2;
    var n = Math.pow(2, zoom);
    var visible = new Set();

    for (var y = Math.max(0, Math.floor(top / tileSize)); y <= Math.min(n - 1, Math.floor((top + height) / tileSize)); y++) {
      for (var x = Math.floor(left / tileSize); x <= Math.floor((left + width) / tileSize); x++) {
        var key = zoom + "/" + x + "/" + y;
        visible.add(key);
        var img = tiles.get(key);
        if (!img) {
          img = document.createElement("img");
          img.alt = "";
          img.draggable = false;
          img.src = "https://tile.openstreetmap.org/" + zoom + "/" + (((x % n) + n) % n) + "/" + y + ".png";
          img.addEventListener("error", function () {
            tileError = true;
            if (!statusEl.textContent.includes("Подложка OpenStreetMap недоступна")) {
              statusEl.appendChild(pill("Подложка OpenStreetMap недоступна", "warn"));
            }
          });
          tileLayer.appendChild(img);
          tiles.set(key, img);
        }
        img.style.left = (x * tileSize - left) + "px";
        img.style.top = (y * tileSize - top) + "px";
      }
    }
    tiles.forEach(function (img, key) {
      if (!visible.has(key)) {
        img.remove();
        tiles.delete(key);
      }
    });

    markers.forEach(function (item) {
      var p = project(item.lon, item.lat, zoom);
      var dx = p[0] - cp[0];
      if (dx > n * tileSize / 2) dx -= n * tileSize;
      if (dx < -n * tileSize / 2) dx += n * tileSize;
      var x = width / 2 + dx;
      var y = height / 2 + p[1] - cp[1];
      item.x = x;
      item.y = y;
      item.visible = (x >= -120 && x <= width + 120 && y >= -80 && y <= height + 80);
      item.el.style.left = x + "px";
      item.el.style.top = y + "px";
      item.el.style.display = item.visible ? "block" : "none";
      item.label.style.display = item.visible ? "block" : "none";
      item.leader.style.display = "none";
    });
    layoutLabels();
  }
  // Markers remain at their exact coordinates. Only labels may move vertically.
  function intersectionArea(a, b, padding) {
    var overlapX = Math.min(a.right, b.right + padding) - Math.max(a.left, b.left - padding);
    var overlapY = Math.min(a.bottom, b.bottom + padding) - Math.max(a.top, b.top - padding);
    return Math.max(0, overlapX) * Math.max(0, overlapY);
  }
  function overlayRectangle(element) {
    var bounds = element.getBoundingClientRect();
    var origin = mapEl.getBoundingClientRect();
    return {
      left: bounds.left - origin.left,
      right: bounds.right - origin.left,
      top: bounds.top - origin.top,
      bottom: bounds.bottom - origin.top
    };
  }
  function layoutLabels() {
    var width = mapEl.clientWidth;
    var height = mapEl.clientHeight;
    if (!width || !height) return;
    var obstacles = [];
    if (statusEl.children.length) obstacles.push(overlayRectangle(statusEl));
    if (peopleControlsEl.children.length) obstacles.push(overlayRectangle(peopleControlsEl));
    obstacles.push(overlayRectangle(controls));
    var occupied = [];
    var visible = Array.from(markers.values()).filter(function (item) { return item.visible; });
    visible.sort(function (a, b) { return a.name.localeCompare(b.name, "ru"); });

    visible.forEach(function (item) {
      var w = item.label.offsetWidth;
      var h = item.label.offsetHeight;
      var x = Math.max(4 + w / 2, Math.min(width - 4 - w / 2, item.x));
      var step = h + 7;
      var best = null;
      for (var rank = 0; rank < 24; rank++) {
        var tier = Math.floor(rank / 2);
        var top = (rank % 2 === 0)
          ? item.y - 20 - h - tier * step
          : item.y + 20 + tier * step;
        var rect = { left: x - w / 2, right: x + w / 2, top: top, bottom: top + h };
        var penalty = rank * 2;
        penalty += Math.max(0, 4 - rect.left) * 1000;
        penalty += Math.max(0, rect.right - width + 4) * 1000;
        penalty += Math.max(0, 4 - rect.top) * 1000;
        penalty += Math.max(0, rect.bottom - height + 4) * 1000;
        occupied.forEach(function (other) { penalty += intersectionArea(rect, other, 5) * 100; });
        obstacles.forEach(function (obstacle) { penalty += intersectionArea(rect, obstacle, 4) * 20; });
        // Prefer the nearest clear position while avoiding other location dots.
        visible.forEach(function (other) {
          if (intersectionArea(rect, {
            left: other.x - 10, right: other.x + 10,
            top: other.y - 10, bottom: other.y + 10
          }, 2)) penalty += 3000;
        });
        if (!best || penalty < best.penalty) best = { top: top, x: x, rect: rect, penalty: penalty };
        if (penalty === 0) break;
      }
      if (!best) return;
      item.label.style.left = best.x + "px";
      item.label.style.top = best.top + "px";
      // Connector makes the marker's real position unambiguous when labels stack.
      var start, end;
      if (best.rect.bottom <= item.y - 8) {
        start = best.rect.bottom;
        end = item.y - 8;
      } else if (best.rect.top >= item.y + 8) {
        start = item.y + 8;
        end = best.rect.top;
      }
      if (start != null && end > start) {
        item.leader.style.left = item.x + "px";
        item.leader.style.top = start + "px";
        item.leader.style.height = (end - start) + "px";
        item.leader.style.display = "block";
      }
      occupied.push(best.rect);
    });
  }
  function zoomAround(newZoom, x, y) {
    newZoom = clamp(newZoom, 1, 19);
    if (newZoom === zoom) return;
    var p = project(center[0], center[1], zoom);
    var worldX = p[0] + x - mapEl.clientWidth / 2;
    var worldY = p[1] + y - mapEl.clientHeight / 2;
    var scale = Math.pow(2, newZoom - zoom);
    zoom = newZoom;
    center = unproject(worldX * scale - x + mapEl.clientWidth / 2,
                       worldY * scale - y + mapEl.clientHeight / 2, zoom);
    redraw();
  }
  function addControl(text, label, delta) {
    var button = document.createElement("button");
    button.type = "button";
    button.textContent = text;
    button.setAttribute("aria-label", label);
    button.addEventListener("click", function () {
      zoomAround(zoom + delta, mapEl.clientWidth / 2, mapEl.clientHeight / 2);
    });
    return button;
  }
  var controls = document.createElement("div");
  controls.className = "map-controls";
  controls.appendChild(addControl("+", "Приблизить", 1));
  controls.appendChild(addControl("−", "Отдалить", -1));
  mapEl.appendChild(controls);

  var attribution = document.createElement("div");
  attribution.className = "map-attribution";
  var link = document.createElement("a");
  link.href = "https://www.openstreetmap.org/copyright";
  link.target = "_blank";
  link.rel = "noopener noreferrer";
  link.textContent = "© OpenStreetMap contributors";
  attribution.appendChild(link);
  mapEl.appendChild(attribution);

  mapEl.addEventListener("pointerdown", function (event) {
    if (event.button !== 0 || event.target.closest("button, a")) return;
    dragging = { id: event.pointerId, x: event.clientX, y: event.clientY };
    mapEl.classList.add("dragging");
    if (mapEl.setPointerCapture) mapEl.setPointerCapture(event.pointerId);
  });
  mapEl.addEventListener("pointermove", function (event) {
    if (!dragging || dragging.id !== event.pointerId) return;
    var p = project(center[0], center[1], zoom);
    center = unproject(p[0] - (event.clientX - dragging.x),
                       p[1] - (event.clientY - dragging.y), zoom);
    dragging.x = event.clientX;
    dragging.y = event.clientY;
    redraw();
  });
  function finishDrag(event) {
    if (dragging && dragging.id === event.pointerId) {
      dragging = null;
      mapEl.classList.remove("dragging");
    }
  }
  mapEl.addEventListener("pointerup", finishDrag);
  mapEl.addEventListener("pointercancel", finishDrag);
  mapEl.addEventListener("lostpointercapture", finishDrag);
  mapEl.addEventListener("wheel", function (event) {
    event.preventDefault();
    var rect = mapEl.getBoundingClientRect();
    zoomAround(zoom + (event.deltaY < 0 ? 1 : -1),
               event.clientX - rect.left, event.clientY - rect.top);
  }, { passive: false });

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
    } else {
      statusEl.appendChild(pill(data.connected ? "2ГИС: подключен" : "2ГИС: переподключение", data.connected ? "ok" : "warn"));
      if (!data.selfSeen) statusEl.appendChild(pill("Своя позиция не опознана автоматически", "warn"));
      if (data.missing && data.missing.length) statusEl.appendChild(pill("Нет данных: " + data.missing.join(", "), "warn"));
    }
    if (tileError) statusEl.appendChild(pill("Подложка OpenStreetMap недоступна", "warn"));
  }
  function marker() {
    var el = document.createElement("div");
    el.className = "person-pin";
    var label = document.createElement("div");
    label.className = "person-label";
    var dot = document.createElement("div");
    dot.className = "person-dot";
    var leader = document.createElement("div");
    leader.className = "person-leader";
    el.appendChild(dot);
    markerLayer.appendChild(el);
    leaderLayer.appendChild(leader);
    labelLayer.appendChild(label);
    return { el: el, label: label, leader: leader };
  }
  function syncPersonButtons(people) {
    var live = new Set();
    people.forEach(function (person) {
      var id = String(person.id || person.name);
      var item = markers.get(id);
      if (!item) return;
      live.add(id);
      var button = personButtons.get(id);
      if (!button) {
        button = document.createElement("button");
        button.type = "button";
        button.addEventListener("click", function () {
          var target = markers.get(id);
          if (!target) return;
          selectedId = id;
          center = [target.lon, target.lat];
          // Deliberately do not change zoom or re-fit other markers.
          personButtons.forEach(function (control, key) {
            control.setAttribute("aria-pressed", String(key === selectedId));
          });
          redraw();
        });
        personButtons.set(id, button);
        peopleControlsEl.appendChild(button);
      }
      button.textContent = person.name;
      button.setAttribute("aria-pressed", String(id === selectedId));
    });
    personButtons.forEach(function (button, id) {
      if (!live.has(id)) {
        button.remove();
        personButtons.delete(id);
        if (selectedId === id) selectedId = null;
      }
    });
  }
  function fit(points) {
    if (points.length === 1) {
      center = points[0];
      zoom = 15;
    } else {
      for (var z = 15; z > 1; z--) {
        var xx = points.map(function (p) { return project(p[0], p[1], z)[0]; });
        var yy = points.map(function (p) { return project(p[0], p[1], z)[1]; });
        if (Math.max.apply(null, xx) - Math.min.apply(null, xx) <= Math.max(1, mapEl.clientWidth - 70) &&
            Math.max.apply(null, yy) - Math.min.apply(null, yy) <= Math.max(1, mapEl.clientHeight - 110)) break;
      }
      zoom = z;
      var xs = points.map(function (p) { return project(p[0], p[1], zoom)[0]; });
      var ys = points.map(function (p) { return project(p[0], p[1], zoom)[1]; });
      center = unproject((Math.min.apply(null, xs) + Math.max.apply(null, xs)) / 2,
                         (Math.min.apply(null, ys) + Math.max.apply(null, ys)) / 2, zoom);
    }
    redraw();
  }
  function render(data) {
    renderStatus(data);
    var visible = new Set();
    var points = [];
    (data.people || []).forEach(function (person) {
      var lat = Number(person.lat);
      var lon = Number(person.lon);
      if (person.lat == null || person.lon == null || !Number.isFinite(lat) || !Number.isFinite(lon) ||
          lat < -maxLat || lat > maxLat || lon < -180 || lon > 180) return;
      var id = String(person.id || person.name);
      visible.add(id);
      var item = markers.get(id);
      if (!item) {
        item = marker();
        markers.set(id, item);
      }
      item.lat = lat;
      item.lon = lon;
      item.name = person.name;
      var label = person.name + " · " + ageText(person.lastSeen);
      if (person.battery != null) label += " · батарея " + person.battery + "%";
      item.label.textContent = label; // Never interpret profile names as HTML.
      points.push([lon, lat]);
    });
    markers.forEach(function (item, id) {
      if (!visible.has(id)) {
        item.el.remove();
        item.label.remove();
        item.leader.remove();
        markers.delete(id);
      }
    });
    syncPersonButtons(data.people || []);
    if (!fitted && points.length) {
      fitted = true;
      fit(points);
    } else {
      redraw();
    }
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
  if (typeof ResizeObserver !== "undefined") {
    new ResizeObserver(redraw).observe(mapEl);
  } else {
    window.addEventListener("resize", redraw);
  }
  redraw();
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


if __name__ == "__main__":
    threading.Thread(target=start_http, name="family-location-http", daemon=True).start()
    asyncio.run(websocket_loop())
