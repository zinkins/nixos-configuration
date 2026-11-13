# Mail.ru Cloud: encrypted Immich backup and cloud photo imports

The NixOS module `nix/immich-mailru-backup.nix` configures a daily encrypted
Restic backup over rclone WebDAV to the **dedicated**
`ImmichBackups/restic` directory in Mail.ru Cloud.

This is a **snapshot backup, not two-way synchronization**. Deleting or
modifying photos inside Immich does not automatically delete their previous
Restic backup versions; the backup retention policy keeps 14 daily, 8 weekly
and 12 monthly snapshots. Only Restic data **inside ImmichBackups/restic**
is pruned. Existing personal and shared Mail.ru photo folders remain intact.

The backup is **off by default** on an unconfigured machine: the systemd
service has file-existence conditions and skips until both private secret
files exist. A successful NixOS build does not verify cloud authentication,
capacity, backups, or restorability.

## Backup contents and regenerable media

Restic snapshots contain all managed original photos/videos (including both
`upload/` and `library/`), profile images, sidecars, and database backups,
including the fresh custom-format PostgreSQL dump. The machine-learning
model cache is outside the backup paths. The contents of `thumbs/` and
`encoded-video/` are excluded, **except** their `.immich` storage-integrity
markers; the parent directories and markers remain in the snapshot.
Existing historical database dumps in `backups/` are kept intentionally:
they are historical recovery points, not regenerable media.

After restoring, preserve the restored file ownership and `.immich` markers,
restore the matching database, then use Administration → Job Queues to run
thumbnail generation and video transcoding for **all** assets. Do not
bypass mount-integrity checks. See the official backup and system-integrity
references below. Regeneration takes CPU time and generated files may be
unavailable until jobs finish.

Restic deduplicates content within its own encrypted repository, not against
ordinary files elsewhere in the Mail.ru account. Imported cloud originals
therefore still participate in the self-contained Restic backup. Adding a
photo already in a user's managed library to a shared album does not create
another original file just because of the album membership. Never exclude
managed originals by album, filename, or supposed cloud presence: the database
references their exact paths, and the old cloud folder can change or disappear.

The historical family archive uses a read-only external library mounted
from Mail.ru. Its originals and VFS cache are outside the managed backup
paths. Restic cannot restore cloud-only originals; reconnect the same remote
folder at the same mount path, and keep an independent copy if possible.
All managed originals still remain in Restic. The original Mail.ru folders
are not modified.

## 1. Create a Mail.ru external-application password

In the Mail account security settings, create a separate **application
password** for WebDAV. Do not use the normal email password. Prefer only the
permissions needed for Cloud/WebDAV access. This is the official WebDAV URL:

```text
https://webdav.cloud.mail.ru
```

Official provider documentation: https://help.mail.ru/cloud/desktop/webdav/

Set up the private rclone configuration **on the NixOS host after deployment**:

```bash
sudo install -d -m 0700 /etc/immich-mailru
sudo rclone config --config /etc/immich-mailru/rclone.conf
```

In the interactive wizard select:
- Remote name: **mailru** (must match the backup repository definition).
- Storage: **WebDAV**, URL: `https://webdav.cloud.mail.ru`
- Vendor: **Other**.
- Username: your Mail.ru login/email.
- Password: the **external application password**.

By default the rclone wizard stores an obfuscated WebDAV password; protect
the entire file. You may additionally encrypt the configuration using the
wizard’s configuration password option. Also configure the URL
`https://webdav.cloud.mail.ru` rather than the normal web UI URL.

```bash
sudo chmod 0600 /etc/immich-mailru/rclone.conf
sudo rclone --config /etc/immich-mailru/rclone.conf lsd mailru:
```

For an encrypted `rclone.conf`, the command above prompts for the **config
encryption password**, separate from the Mail.ru application password and
Restic encryption password. `sudo immich-setup` detects encryption and asks
whether to save this password in `/etc/immich-mailru/rclone-config-password`
(root-only, mode `0600`). It validates decryption before saving; existing
password files are never overwritten. The daily service and
`restic-immich-mailru` wrapper use rclone's `password-command` to read it.
The config remains encrypted. This permits unattended backups, but root can
read both files; it does not protect against a compromised host. Keep a
separate safe copy of the config password and never send it in chat or Git.
Without this file an encrypted config cannot be used by the daily service.
If you later change the config password, update the private password file
locally as root too. Do not replace `restic-password`.

The setup wizard distinguishes a local config/decryption failure from a
remote listing failure. The latter can mean an incorrect remote name,
WebDAV credentials, URL or network problem; it does not prove a Mail.ru outage.
To diagnose interactively, rerun the read-only `rclone lsd` command above;
its output can contain private folder names, so do not publish it unredacted.

First confirm that the expected cloud folders are visible. Do not use
`rclone sync`, `delete`, `purge` or `move` on the original cloud folders.

## 2. Create and save a separate Restic encryption password

```bash
sudo sh -c 'umask 077; head -c 48 /dev/urandom | base64 > /etc/immich-mailru/restic-password'
sudo chmod 0600 /etc/immich-mailru/restic-password
```

Store this encryption password **outside the NixOS host**, in an offline or
separately backed-up password manager. **Losing it means losing access to
every encrypted backup**, even if the cloud files remain intact. Neither
this password nor the Mail.ru application password belongs in Git or chat.

## 3. Test the first backup before relying on the timer

The automatic timer runs daily at approximately 03:30-04:00
**Asia/Novosibirsk** (system's local time), persistent after downtime.
It requires mounted ZFS media and a running PostgreSQL service, and creates
a consistent logical `pg_dump` of the Immich database before uploading files.

```bash
sudo systemctl start restic-backups-immich-mailru.service
sudo systemctl status restic-backups-immich-mailru.service --no-pager
sudo journalctl -u restic-backups-immich-mailru.service -n 100 --no-pager
sudo restic-immich-mailru snapshots
```

A backup that completes without errors is not sufficient: regularly
**restore-test** a snapshot to a separate staging directory and verify the
media files and `immich.pgcustom` database dump:

```bash
sudo mkdir -p /var/tmp/immich-restore-test
sudo restic-immich-mailru restore latest --target /var/tmp/immich-restore-test
sudo find /var/tmp/immich-restore-test -name immich.pgcustom -print
```

Do **not** restore on top of a live Immich installation. Review the files,
test PostgreSQL restoration to a disposable database/server, and remove the
temporary restore directory when testing is complete. Full snapshots can
be large; restore only selected paths for quick routine checks.

The DB dump is produced **first**, then the media directory is copied. Since
uploads can continue during backup, the two copies may not be perfectly
atomic. Immich's recommended order is DB first, files second; take an
offline or snapshot-consistent backup for a strict recovery point.

The remote encrypted repository is **not** intended as a browsable photo
gallery. Your existing Mail.ru folders remain browsable; Restic snapshots
are for disaster recovery.

## 4. Direct read-only family archive (recommended for the selected workflow)

Run `sudo immich-setup` after WebDAV and the shared album are ready.
Select direct archive setup and enter the exact cloud folder path relative
to the Mail.ru root. The wizard lists supported media and asks you to confirm
adding **all** of them to the existing selected family album. If a public
share link already exists, the added photos become visible to its recipients.

The service mounts only that folder at `/mnt/immich-family-archive` with
rclone WebDAV, read-only, using the existing root-only rclone configuration.
The persistent VFS cache on ZFS is limited approximately to 20 GiB (not a
hard quota; open files can exceed it). The mount is restarted on boot and
does not block the managed Immich library or phone uploads on cloud failure.
The source path is stored locally, never committed to Git.

The wizard creates an external library owned by the existing album owner,
disables **global** scheduled external-library scans and filesystem watching
with confirmation, and queues a single initial scan. A background worker
waits for the library queue, verifies indexed paths against the original
remote listing, then adds only matching visible assets not already in the
album. It stores progress locally and revokes temporary narrowly scoped
API keys on success. Repeated runs do not scan or add again. No original
files are copied into managed Immich storage, and no originals are changed
in Mail.ru. Hidden Live Photo video companions are not separate album entries.

If the cloud is unavailable, the worker waits; a partial scan, duplicates
deduplicated by Immich, or other path discrepancies can leave the status
"requires review" instead of falsely reporting success. Do not run a full
rescan or remove the library while the cloud is unreachable. The operator
state is under `/var/lib/immich-operator`; do not delete it to force a retry.
Check `systemctl status immich-family-archive immich-archive-worker` and
`journalctl -u immich-archive-worker`. For failed/partial initialization,
review the actual library and queue in the Immich admin UI before retrying;
automatic recovery of partially failed scans is intentionally not implemented.
The initial import is not a recurring cloud-to-album sync.

**Backup tradeoff:** the cloud-only originals have no independent second
copy. Restic backs up managed phone originals and the database, not the
WebDAV mount or cache. A restore requires reconnecting the identical remote
folder at the identical mount path; do not move/rename/delete cloud files.
Consider a separate offline copy of the historical archive for real disaster
recovery. The cloud folder may be unavailable without Internet access.

The separate incoming phone-upload folder can still be imported once into
the appropriate private user via a non-destructive `rclone copy` to a
private staging directory and Immich CLI, if needed. Never copy files directly
into managed storage. Do not import the cloud family folder via CLI in this
workflow, since this duplicates originals and Restic storage. Other NAS
archives remain untouched.

Official references:
- https://help.mail.ru/cloud/desktop/webdav/
- https://rclone.org/webdav/
- https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html
- https://docs.immich.app/administration/backup-and-restore/
- https://docs.immich.app/administration/system-integrity/
- https://restic.readthedocs.io/en/stable/040_backup.html#excluding-files
