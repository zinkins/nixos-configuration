{ pkgs, ... }:

let
  homepagePort = 8082;
  statusPort = 8083;
  redsocksPort = 12345;

  # api.open-meteo.com A record returned for this host. Our upstream ISP blocks
  # this Hetzner range directly, and homepage's weather widget uses a raw
  # https.Agent request with no proxy support of any kind (no HTTPS_PROXY,
  # no NODE_USE_ENV_PROXY — those only affect the global fetch(), which this
  # widget doesn't use). So the only way to route it through the loopback
  # SOCKS5 VPN proxy is a transparent redirect below the application: iptables
  # sends locally-generated connections to this IP:443 into redsocks, which
  # relays them over the SOCKS5 proxy without homepage knowing a proxy exists.
  openMeteoIp = "157.90.83.168";

  # AmneziaWG's assigned tunnel address (nix/amnezia.nix binds media-vpn-proxy's
  # outbound socket to this address so its packets hit the awg0 policy route).
  # Without excluding it below, microsocks' own connect() to openMeteoIp would
  # match the redirect rule too and loop back into redsocks forever.
  vpnTunnelIp = "10.8.1.10";

  redsocksConfig = pkgs.writeText "homepage-redsocks.conf" ''
    base {
      log_debug = off;
      log_info = off;
      daemon = off;
      redirector = iptables;
    }
    redsocks {
      local_ip = 127.0.0.1;
      local_port = ${toString redsocksPort};
      ip = 127.0.0.1;
      port = 1080;
      type = socks5;
    }
  '';

  familyStatusApi = pkgs.writeText "family-status.py" ''
    import json
    import os
    import subprocess
    import threading
    import time
    from datetime import datetime
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    IP = "${pkgs.iproute2}/bin/ip"
    CURL = "${pkgs.curl}/bin/curl"
    ZPOOL = "${pkgs.zfs}/bin/zpool"

    # The same Open-Meteo URL/IP and transparent VPN route used by Homepage.
    # Fetch locally so CustomAPI's dynamic-list can display API-derived clock
    # times instead of its otherwise static per-row labels.
    WEATHER_URL = (
        "https://api.open-meteo.com/v1/forecast?"
        "latitude=55.0084&longitude=82.9357&timezone=Asia%2FNovosibirsk"
        "&forecast_hours=25&wind_speed_unit=ms"
        "&hourly=temperature_2m,precipitation_probability,wind_speed_10m"
    )
    WEATHER_CACHE = {"payload": None, "expires": 0}
    WEATHER_LOCK = threading.Lock()

    def weather_forecast():
        with WEATHER_LOCK:
            now = time.monotonic()
            if WEATHER_CACHE["payload"] is not None and now < WEATHER_CACHE["expires"]:
                return WEATHER_CACHE["payload"]

            try:
                response = subprocess.run(
                    [
                        CURL, "--ipv4", "--noproxy", "*",
                        "--resolve", "api.open-meteo.com:443:${openMeteoIp}",
                        "--fail", "--silent", "--show-error",
                        "--connect-timeout", "5", "--max-time", "15",
                        WEATHER_URL,
                    ],
                    capture_output=True,
                    text=True,
                    check=True,
                    timeout=17,
                )
                hourly = json.loads(response.stdout)["hourly"]
                forecast = []
                # Open-Meteo returns local times because the request includes
                # timezone=Asia/Novosibirsk. The first element is this hour.
                for index in (0, 6, 12, 18, 24):
                    timestamp = datetime.fromisoformat(hourly["time"][index])
                    temperature = float(hourly["temperature_2m"][index])
                    rain = float(hourly["precipitation_probability"][index])
                    wind = float(hourly["wind_speed_10m"][index])
                    forecast.append({
                        "time": timestamp.strftime("%d.%m %H:%M"),
                        "forecast": (
                            f"{temperature:.0f}° · осадки {rain:.0f}%"
                            f" · ветер {wind:.0f} м/с"
                        ),
                    })
                payload = {"hours": forecast}
            except (OSError, subprocess.SubprocessError, ValueError, KeyError, IndexError, TypeError) as exc:
                # Serve last known values during a temporary outage, avoiding
                # an empty dashboard. The timestamps remain absolute.
                if WEATHER_CACHE["payload"] is not None:
                    print(f"Weather refresh failed; serving cached forecast: {exc}", flush=True)
                    WEATHER_CACHE["expires"] = now + 60
                    return WEATHER_CACHE["payload"]
                raise

            WEATHER_CACHE["payload"] = payload
            WEATHER_CACHE["expires"] = now + 600
            return payload

    def run(command, timeout=3):
        try:
            return subprocess.check_output(
                command,
                text=True,
                stderr=subprocess.DEVNULL,
                timeout=timeout,
            ).strip()
        except (subprocess.SubprocessError, OSError):
            return ""

    def vpn_status():
        vpn_ip = ""
        output = run([IP, "-4", "-o", "addr", "show", "dev", "awg0"])
        if output:
            fields = output.split()
            try:
                vpn_ip = fields[fields.index("inet") + 1].split("/", 1)[0]
            except (ValueError, IndexError):
                pass

        vpn_up = bool(os.path.exists("/sys/class/net/awg0") and vpn_ip)
        internet_ok = False
        if vpn_up:
            # Binding curl to awg0's source address selects routing table 51820
            # from nix/amnezia.nix, so this tests egress through the VPN rather
            # than the host's normal default route.  The target is an IP literal
            # to keep DNS availability out of the connectivity check.
            http_code = run([
                CURL,
                "--interface", vpn_ip,
                "--silent",
                "--show-error",
                "--output", "/dev/null",
                "--write-out", "%{http_code}",
                "--connect-timeout", "2",
                "--max-time", "4",
                "https://1.1.1.1/cdn-cgi/trace",
            ], timeout=5)
            internet_ok = bool(http_code and http_code[0] in ("2", "3"))

        return {
            "vpn": "Подключен" if vpn_up else "Отключен",
            "vpnIp": vpn_ip or "—",
            "vpnInternet": "Доступен" if internet_ok else "Нет доступа",
        }

    def zfs_status():
        output = run([ZPOOL, "list", "-H", "-o", "health,capacity", "myraid1"])
        if not output:
            return {"zfs": "Недоступен", "zfsUsed": "—"}

        fields = output.split("\t")
        return {
            "zfs": fields[0] if fields else "Недоступен",
            "zfsUsed": fields[1] if len(fields) > 1 else "—",
        }

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/weather":
                try:
                    payload = weather_forecast()
                except (OSError, subprocess.SubprocessError, ValueError, KeyError, IndexError, TypeError) as exc:
                    print(f"Weather forecast unavailable: {exc}", flush=True)
                    payload = {"error": "Weather forecast is unavailable"}
                    self.send_response(502)
                else:
                    self.send_response(200)
            elif self.path == "/immich":
                try:
                    with open("/run/immich-health/status.json", encoding="utf-8") as file:
                        payload = json.load(file)
                    if time.time() - payload["checkedAt"] > 900:
                        payload = {"immich": "Диагностика устарела", "backup": "Неизвестно", "remote": "Неизвестно"}
                except (OSError, ValueError, KeyError, TypeError):
                    payload = {"immich": "Ожидает диагностики", "backup": "Неизвестно", "remote": "Неизвестно"}
                self.send_response(200)
            elif self.path == "/status":
                payload = {}
                payload.update(vpn_status())
                payload.update(zfs_status())
                self.send_response(200)
            else:
                self.send_response(404)
                self.end_headers()
                return

            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format, *args):
            return

    ThreadingHTTPServer(("127.0.0.1", ${toString statusPort}), Handler).serve_forever()
  '';
in
{
  services.homepage-dashboard = {
    enable = true;
    listenPort = homepagePort;
    openFirewall = false;
    allowedHosts = "family.home,localhost:${toString homepagePort},127.0.0.1:${toString homepagePort}";

    settings = {
      title = "family.home";
      description = "Домашние сервисы, состояние дома и семейная информация";
      language = "ru";
      theme = "dark";
      color = "slate";
      headerStyle = "boxedWidgets";
      statusStyle = "dot";
      target = "_self";
      fullWidth = true;
      maxGroupColumns = 4;
      useEqualHeights = true;
      disableCollapse = false;
      disableIndexing = true;
      hideVersion = true;
      iconStyle = "theme";
      quicklaunch = {
        searchDescriptions = true;
        hideInternetSearch = true;
        hideVisitURL = true;
        mobileButtonPosition = "top-right";
      };

      # A list, not an attrset: Nix sorts attrset keys alphabetically, and
      # homepage orders groups by layout key order. Homepage accepts a list of
      # single-key maps and keeps its order.
      layout = [
        {
          "Погода" = {
            style = "row";
            columns = 1;
            icon = "mdi-weather-partly-cloudy";
          };
        }
        {
          "Медиа" = {
            style = "row";
            columns = 1;
            icon = "mdi-play-circle";
          };
        }
        {
          "Загрузки и сеть" = {
            style = "row";
            columns = 4;
            icon = "mdi-lan";
          };
        }
        {
          "Хранилище" = {
            style = "row";
            columns = 1;
            icon = "mdi-database";
          };
        }
        {
          "Семья" = {
            style = "row";
            columns = 3;
            icon = "mdi-account-group";
          };
        }
        {
          "Быстрый доступ" = {
            style = "row";
            columns = 4;
            icon = "mdi-link-variant";
          };
        }
        {
          "Дом" = {
            style = "row";
            columns = 4;
            icon = "mdi-home-heart";
          };
        }
      ];
    };

    widgets = [
      {
        resources = {
          label = "Сервер";
          cpu = true;
          memory = true;
          disk = [ "/" ];
          cputemp = true;
          uptime = true;
          network = true;
          units = "metric";
          refresh = 5000;
        };
      }
      {
        openmeteo = {
          label = "Новосибирск";
          latitude = 55.0084;
          longitude = 82.9357;
          timezone = "Asia/Novosibirsk";
          units = "metric";
          cache = 5;
          format.maximumFractionDigits = 0;
        };
      }
      {
        datetime = {
          locale = "ru-RU";
          text_size = "xl";
          format = {
            dateStyle = "long";
            timeStyle = "short";
            hourCycle = "h23";
          };
        };
      }
    ];

    services = [
      {
        # CustomAPI does not support API-derived dynamic labels in list mode.
        # Serve five timestamped rows from the loopback weather endpoint instead.
        # The API supplies real Novosibirsk local date/time for every forecast;
        # intervals remain 0, 6, 12, 18, and 24 hours from its current hour.
        "Погода" = [
          {
            "Прогноз на 24 часа" = {
              icon = "mdi-weather-partly-cloudy";
              description = "Новосибирск · время / температура / осадки / ветер";
              widget = {
                type = "customapi";
                url = "http://127.0.0.1:${toString statusPort}/weather";
                refreshInterval = 1800000;
                display = "dynamic-list";
                mappings = {
                  items = "hours";
                  name = "time";
                  label = "forecast";
                  limit = 5;
                  format = "text";
                };
              };
            };
          }
        ];
      }
      {
        "Медиа" = [
          {
            Jellyfin = {
              icon = "jellyfin.png";
              href = "http://jellyfin.home";
              description = "Фильмы, сериалы и музыка";
              siteMonitor = "http://127.0.0.1:8096";
            };
          }
          {
            Immich = {
              icon = "immich.png";
              href = "http://photos.home";
              description = "Семейные фотографии и общие альбомы";
              siteMonitor = "http://127.0.0.1:2283";
              widget = {
                type = "customapi";
                url = "http://127.0.0.1:${toString statusPort}/immich";
                refreshInterval = 60000;
                mappings = [
                  { field = "immich"; label = "Immich"; }
                  { field = "version"; label = "Версия"; }
                  { field = "photos"; label = "Фото"; }
                  { field = "videos"; label = "Видео"; }
                  { field = "usage"; label = "Медиа"; }
                  { field = "backup"; label = "Бэкап"; }
                  { field = "lastBackup"; label = "Последний"; }
                  { field = "remote"; label = "HTTPS"; }
                  { field = "archive"; label = "Семейный архив"; }
                ];
              };
            };
          }
        ];
      }
      {
        "Загрузки и сеть" = [
          {
            qBittorrent = {
              icon = "qbittorrent.png";
              href = "http://qbittorrent.home";
              description = "Загрузки";
              siteMonitor = "http://127.0.0.1:8080";
              widget = {
                type = "qbittorrent";
                url = "http://127.0.0.1:8080";
                fields = [ "leech" "download" "seed" "upload" ];
                enableLeechProgress = true;
                enableLeechSize = true;
              };
            };
          }
          {
            Prowlarr = {
              icon = "prowlarr.png";
              href = "http://prowlarr.home";
              description = "Индексаторы";
              siteMonitor = "http://127.0.0.1:9696";
            };
          }
          {
            "AdGuard Home" = {
              icon = "adguard-home.png";
              href = "http://adguard.home";
              description = "DNS и блокировка рекламы";
              siteMonitor = "http://127.0.0.1:3000";
            };
          }
          {
            AmneziaWG = {
              icon = "mdi-vpn";
              description = "VPN для домашних сервисов";
              widget = {
                type = "customapi";
                url = "http://127.0.0.1:${toString statusPort}/status";
                refreshInterval = 10000;
                mappings = [
                  {
                    field = "vpn";
                    label = "VPN";
                  }
                  {
                    field = "vpnInternet";
                    label = "Интернет через VPN";
                  }
                  {
                    field = "vpnIp";
                    label = "IP туннеля";
                  }
                ];
              };
            };
          }
        ];
      }
      {
        "Хранилище" = [
          {
            "ZFS myraid1" = {
              icon = "mdi-database";
              description = "Хранилище фильмов и данных";
              widget = {
                type = "customapi";
                url = "http://127.0.0.1:${toString statusPort}/status";
                refreshInterval = 10000;
                mappings = [
                  {
                    field = "zfs";
                    label = "ZFS";
                  }
                  {
                    field = "zfsUsed";
                    label = "Пул занят";
                  }
                ];
              };
            };
          }
        ];
      }
      {
        "Дом" = [
          {
            "CO₂" = {
              icon = "mdi-molecule-co2";
              description = "Датчик качества воздуха — подключим позже";
            };
          }
          {
            "Датчики протечки" = {
              icon = "mdi-water-alert";
              description = "Контроль воды — подключим позже";
            };
          }
          {
            "Тёплый пол" = {
              icon = "mdi-heating-coil";
              description = "Температура и управление — подключим позже";
            };
          }
          {
            "Температура дома" = {
              icon = "mdi-home-thermometer";
              description = "Климат по комнатам — подключим позже";
            };
          }
        ];
      }
      {
        "Семья" = [
          {
            "Электронный дневник" = {
              icon = "mdi-school";
              href = "https://school.nso.ru/journal-app/";
              description = "Уроки и домашние задания";
              widget = {
                type = "customapi";
                url = "http://127.0.0.1:8084/data";
                refreshInterval = 60000;
                display = "dynamic-list";
                mappings = {
                  items = "items";
                  name = "name";
                  label = "label";
                  limit = 10;
                };
              };
            };
          }
          {
            "Семейный календарь" = {
              icon = "mdi-calendar-heart";
              description = "События и напоминания — подключим позже";
            };
          }
        ];
      }
    ];

    bookmarks = [
      {
        "Быстрый доступ" = [
          {
            Jellyfin = [
              {
                icon = "jellyfin.png";
                href = "http://jellyfin.home";
                description = "Медиатека";
              }
            ];
          }
          {
            Immich = [
              {
                icon = "immich.png";
                href = "http://photos.home";
                description = "Фото семьи";
              }
            ];
          }
          {
            qBittorrent = [
              {
                icon = "qbittorrent.png";
                href = "http://qbittorrent.home";
                description = "Загрузки";
              }
            ];
          }
          {
            Prowlarr = [
              {
                icon = "prowlarr.png";
                href = "http://prowlarr.home";
                description = "Поиск контента";
              }
            ];
          }
          {
            "AdGuard Home" = [
              {
                icon = "adguard-home.png";
                href = "http://adguard.home";
                description = "DNS";
              }
            ];
          }
        ];
      }
    ];

    # High-contrast dark theme: near-black background, solid cards with a
    # visible border, and white text instead of homepage's dimmed defaults.
    customCSS = ''
      body {
        background: linear-gradient(180deg, #02060d 0%, #050b16 100%) !important;
        background-attachment: fixed !important;
        color: #ffffff !important;
      }

      .service-card,
      .bookmark > a,
      #information-widgets .widget-container {
        background-color: #0f1b2d !important;
        border: 1px solid #3b4f6b !important;
        color: #ffffff !important;
      }

      .service-card:hover,
      .bookmark > a:hover {
        background-color: #172a45 !important;
        border-color: #60a5fa !important;
      }

      .service-group-name,
      .service-name,
      .primary-text,
      .secondary-text,
      .bookmark-text,
      .service-block div,
      .widget-container div {
        color: #ffffff !important;
      }

      .service-description,
      .bookmark-description {
        color: #cbd5e1 !important;
      }

      .service-block,
      .service-card .rounded-sm {
        background-color: #1e3150 !important;
      }
    '';
  };

  systemd.services.family-status = {
    description = "Loopback status API for family.home";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    # zpool queries /dev/zfs, so this service stays root while the endpoint is
    # constrained to loopback and the unit is otherwise strongly hardened.
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.python3}/bin/python ${familyStatusApi}";
      Restart = "on-failure";
      RestartSec = 2;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_NETLINK" ];
    };
  };

  systemd.services.homepage-redsocks = {
    description = "Transparent SOCKS5 redirector for homepage's Open-Meteo requests";
    wantedBy = [ "multi-user.target" ];
    requires = [ "media-vpn-proxy.service" ];
    after = [ "media-vpn-proxy.service" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.redsocks}/bin/redsocks -c ${redsocksConfig}";
      Restart = "on-failure";
      RestartSec = 2;
      DynamicUser = true;
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
    wants = [ "family-status.service" "homepage-redsocks.service" ];
    after = [ "family-status.service" "homepage-redsocks.service" ];
  };

  # Locally-generated connections to Open-Meteo get transparently rewritten
  # to homepage-redsocks; everything else is untouched. Scoped to this one
  # destination IP:port so no other traffic on the host is affected.
  #
  # The rule lives in its own chain that gets unconditionally flushed and
  # rebuilt on every run, rather than a bare "iptables -D <exact rule> || true"
  # before the -A: `-D` only matches an *exact* rule spec, so any past edit to
  # this rule's flags leaves the previous variant stuck in the table forever
  # (silently, since the delete is swallowed by `|| true`) — which is exactly
  # what caused a REDIRECT loop in practice: media-vpn-proxy's own outbound
  # connect() (source-bound to vpnTunnelIp) kept matching a stale rule that
  # predated the "! -s vpnTunnelIp" exclusion below.
  networking.firewall.extraCommands = ''
    # One-time cleanup of exact-match rules from earlier revisions of this
    # fix that predate the dedicated chain below.
    iptables -t nat -D OUTPUT -p tcp -d ${openMeteoIp} --dport 443 -j REDIRECT --to-port ${toString redsocksPort} 2>/dev/null || true
    iptables -t nat -D OUTPUT -p tcp -d ${openMeteoIp} --dport 443 ! -s ${vpnTunnelIp} -j REDIRECT --to-port ${toString redsocksPort} 2>/dev/null || true

    iptables -t nat -N homepage-weather-redirect 2>/dev/null || true
    iptables -t nat -F homepage-weather-redirect
    iptables -t nat -A homepage-weather-redirect -p tcp -d ${openMeteoIp} --dport 443 ! -s ${vpnTunnelIp} -j REDIRECT --to-port ${toString redsocksPort}

    iptables -t nat -D OUTPUT -j homepage-weather-redirect 2>/dev/null || true
    iptables -t nat -A OUTPUT -j homepage-weather-redirect
  '';
  networking.firewall.extraStopCommands = ''
    iptables -t nat -D OUTPUT -j homepage-weather-redirect 2>/dev/null || true
    iptables -t nat -F homepage-weather-redirect 2>/dev/null || true
    iptables -t nat -X homepage-weather-redirect 2>/dev/null || true
  '';
}
