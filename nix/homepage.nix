{ pkgs, ... }:

let
  homepagePort = 8082;
  statusPort = 8083;

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

      layout = {
        "Медиа" = {
          style = "row";
          columns = 1;
          icon = "mdi-play-circle";
        };
        "Загрузки и сеть" = {
          style = "row";
          columns = 4;
          icon = "mdi-lan";
        };
        "Дом" = {
          style = "row";
          columns = 4;
          icon = "mdi-home-heart";
        };
        "Семья" = {
          style = "row";
          columns = 3;
          icon = "mdi-account-group";
        };
        "Быстрый доступ" = {
          style = "row";
          columns = 4;
          icon = "mdi-link-variant";
        };
      };
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

    customCSS = ''
      body {
        background:
          radial-gradient(circle at 15% 15%, rgba(37, 99, 235, 0.20), transparent 34%),
          radial-gradient(circle at 85% 10%, rgba(14, 116, 144, 0.14), transparent 28%),
          linear-gradient(155deg, #07111f 0%, #0b1728 48%, #07101d 100%) !important;
        background-attachment: fixed !important;
      }

      @media (max-width: 768px) {
        body {
          background:
            radial-gradient(circle at 50% 0%, rgba(37, 99, 235, 0.22), transparent 32%),
            linear-gradient(180deg, #07111f 0%, #091829 50%, #07101d 100%) !important;
        }
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

  systemd.services.homepage-dashboard = {
    wants = [ "family-status.service" ];
    after = [ "family-status.service" ];
  };
}
