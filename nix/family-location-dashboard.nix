{ lib, ... }:

{
  # Keep the map in its own full-width group. The iframe stays on the same
  # family.home origin and is routed by Caddy to the loopback-only service.
  services.homepage-dashboard.settings.layout = lib.mkAfter [
    {
      "Геолокация" = {
        style = "row";
        columns = 1;
        icon = "mdi-map-marker-account";
      };
    }
  ];

  services.homepage-dashboard.services = lib.mkAfter [
    {
      "Геолокация" = [
        {
          "Карта" = {
            icon = "mdi-map-marker-account";
            description = "Выбранные люди из 2ГИС";
            widget = {
              type = "iframe";
              name = "family-location";
              src = "http://family.home/family-location/";
              classes = "h-96";
              referrerPolicy = "same-origin";
              allowFullscreen = false;
              allowScrolling = "no";
            };
          };
        }
      ];
    }
  ];
}
