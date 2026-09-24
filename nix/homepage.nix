{ pkgs, ... }:

let
  homepagePort = 8082;
  statusPort = 8083;
  redsocksPort = 12345;

  # api.open-meteo.com's only A record. Our upstream ISP blocks this Hetzner
  # range directly, and homepage's own weather-widget HTTP client is a raw
  # https.Agent request with no proxy support of any kind (no HTTPS_PROXY,
  # no NODE_USE_ENV_PROXY — those only affect the global fetch(), which this
  # widget doesn't use). So the only way to route it through the loopback
  # SOCKS5 VPN proxy is a transparent redirect below the application: iptables
  # sends locally-generated connections to this IP:443 into redsocks, which
  # relays them over the SOCKS5 proxy without homepage knowing a proxy exists.
  openMeteoIp = "94.130.142.35";

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
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    IP = "${pkgs.iproute2}/bin/ip"
    ZPOOL = "${pkgs.zfs}/bin/zpool"

    def run(command):
        try:
            return subprocess.check_output(
                command,
                text=True,
                stderr=subprocess.DEVNULL,
                timeout=3,
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

        return {
            "vpn": "Подключен" if os.path.exists("/sys/class/net/awg0") and vpn_ip else "Отключен",
            "vpnIp": vpn_ip or "—",
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
            if self.path != "/status":
                self.send_response(404)
                self.end_headers()
                return

            payload = {}
            payload.update(vpn_status())
            payload.update(zfs_status())
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")

            self.send_response(200)
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
          disk = [ "/" "/myraid1" ];
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
        # The openmeteo info widget above only shows current conditions, so the
        # day forecast is a customapi card on the same API host (and therefore
        # the same VPN redirect below). hourly.temperature_2m.N is hour N of
        # today in the given timezone, since forecast_days=1.
        "Погода" = [
          {
            "Прогноз на сегодня" = {
              icon = "mdi-weather-partly-cloudy";
              description = "Новосибирск";
              widget = {
                type = "customapi";
                url = "https://api.open-meteo.com/v1/forecast?latitude=55.0084&longitude=82.9357&timezone=Asia%2FNovosibirsk&forecast_days=1&wind_speed_unit=ms&hourly=temperature_2m&daily=temperature_2m_min,temperature_2m_max,precipitation_probability_max,precipitation_sum,wind_speed_10m_max";
                refreshInterval = 1800000;
                display = "list";
                mappings = [
                  { field = "hourly.temperature_2m.8"; label = "Утро (08:00)"; format = "number"; suffix = "°"; }
                  { field = "hourly.temperature_2m.14"; label = "День (14:00)"; format = "number"; suffix = "°"; }
                  { field = "hourly.temperature_2m.20"; label = "Вечер (20:00)"; format = "number"; suffix = "°"; }
                  { field = "hourly.temperature_2m.2"; label = "Ночь (02:00)"; format = "number"; suffix = "°"; }
                  {
                    field = "daily.temperature_2m_min.0";
                    label = "Мин / макс";
                    format = "number";
                    suffix = "°";
                    additionalField = {
                      field = "daily.temperature_2m_max.0";
                      format = "number";
                      suffix = "°";
                    };
                  }
                  {
                    field = "daily.precipitation_probability_max.0";
                    label = "Осадки";
                    format = "number";
                    suffix = "%";
                    additionalField = {
                      field = "daily.precipitation_sum.0";
                      format = "float";
                      suffix = "мм";
                    };
                  }
                  { field = "daily.wind_speed_10m_max.0"; label = "Ветер до"; format = "number"; suffix = "м/с"; }
                ];
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
              siteMonitor = "http://127.0.0.1:${toString statusPort}/status";
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
                    field = "vpnIp";
                    label = "IP";
                  }
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
            "Геолокация детей" = {
              icon = "mdi-map-marker-account";
              description = "2ГИС или другой источник — подключим позже";
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
