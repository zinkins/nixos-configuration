# Samba share for the NAS

The NAS dataset `/myraid1/nas` is shared over SMB as `nas`, so Windows can map it as a network drive:

```text
\\nixos.home\nas
```

The NixOS side is defined in [`../nix/samba.nix`](../nix/samba.nix).

## Access model

- Only the account listed in `valid users` in `nix/samba.nix` can connect (called `<USER>` below). Guest access is disabled.
- The Samba password is separate from the Linux login password. It lives only in the server's Samba database under `/var/lib/samba/private`, is never stored in Git, and survives rebuilds.
- Samba accepts clients only from `192.168.0.0/16` (`hosts allow`). The NixOS firewall opens the SMB ports on every interface, but connections arriving through `awg0`, `wg-home` or the AI VPN namespace are rejected by Samba itself. The share is therefore not reachable through the home VPN; remote clients only get Caddy (see `HOME-VPN.md`).
- If the LAN is ever renumbered outside `192.168.0.0/16`, update `hosts allow` in `nix/samba.nix`.

## Permissions

Files are accessed with `<USER>`'s normal Unix permissions:

- folders owned by `<USER>` are read/write;
- `films` belongs to `qbittorrent:media` with the setgid bit. `<USER>` is a member of the `media` group, so the directory is writable over SMB. Files and folders created over SMB get mode `0664`/`0775`, and the setgid bit gives them group `media`, so qBittorrent and Jellyfin keep access to them;
- qBittorrent runs with `UMask=0002`, so new downloads are group-writable and can be renamed or deleted from Windows.

Prefer removing a torrent's data in qBittorrent ("remove with files"). Deleting it from Windows leaves the torrent in qBittorrent with missing files.

## One-time setup on the server

After the configuration has been deployed:

1. Create the Samba password for `<USER>` (it is asked interactively; run the same command later to change it):

   ```bash
   sudo smbpasswd -a <USER>
   ```

   Check that the account exists:

   ```bash
   sudo pdbedit -L
   ```

2. Make content that already existed in `films` group-writable. qBittorrent created it with the previous `UMask=0022`, and leftovers from an older system may belong to unknown groups:

   ```bash
   sudo chgrp -R media /myraid1/nas/films
   sudo chmod -R g+rwX /myraid1/nas/films
   sudo find /myraid1/nas/films -type d -exec chmod g+s {} +
   ```

The new `media` group membership applies to new sessions: reconnect the network drive, and log in again over SSH.

## Connect from Windows

In Explorer open **This PC → Map network drive**:

```text
Folder:  \\nixos.home\nas
[x] Reconnect at sign-in
[x] Connect using different credentials
```

Enter `<USER>` and the Samba password, and tick **Remember my credentials**.

The same from PowerShell (`cmdkey` prompts for the password):

```powershell
cmdkey /add:nixos.home /user:<USER> /pass
net use Z: \\nixos.home\nas /persistent:yes
```

`nixos.home` requires the client to use AdGuard Home as its DNS server (see `REVERSE-PROXY.md`). `\\nixos\nas` (NetBIOS) and `\\<SERVER_IP>\nas` also work, but Windows treats each form as a different server for saved credentials, so use one form consistently.

## Verify

On the server:

```bash
systemctl status samba-smbd samba-nmbd --no-pager
testparm -s
smbclient //localhost/nas -U <USER> -c 'ls'
```

From Windows:

```powershell
Test-NetConnection nixos.home -Port 445
```

## Troubleshooting

### Access denied or wrong password

Confirm the Samba account exists (`sudo pdbedit -L`). If Windows keeps sending old credentials, remove the mapping and the saved credentials, then connect again:

```powershell
net use Z: /delete
cmdkey /delete:nixos.home
```

### System error 1219

Windows allows only one set of credentials per server name. List the existing connections with `net use`, delete the ones to the same server, and reconnect.

### Connection refused from the LAN

Check that the client address is inside `192.168.0.0/16`, then look for `Denied connection from` in `journalctl -u samba-smbd -b` or under `/var/log/samba/`.

### Cannot change files in `films`

Run the one-time permission step above, check that `id <USER>` lists `media`, and reconnect the network drive.
