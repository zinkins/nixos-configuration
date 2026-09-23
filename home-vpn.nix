{ ... }:

{
  networking.wg-quick.interfaces.wg-home = {
    autostart = true;
    address = [ "10.77.77.2/30" ];
    privateKeyFile = "/etc/wireguard/wg-home.key";
    generatePrivateKeyFile = true;

    peers = [
      {
        publicKey = "RicqeDa+QbDBYXzEaYRIIdIlhzdFH5YbL1a+mecRaxQ=";
        endpoint = "45.139.76.234:51822";
        allowedIPs = [
          "10.77.77.1/32"
          "172.29.172.2/32"
        ];
        persistentKeepalive = 25;
      }
    ];
  };

  systemd.tmpfiles.rules = [ "d /etc/wireguard 0700 root root -" ];
}
