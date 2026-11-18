# Local ZFS snapshots

The declarative policy in [../nix/zfs.nix](../nix/zfs.nix) uses Sanoid to
protect the NAS dataset and its descendants. It runs hourly to check
whether a scheduled snapshot is due, not to create hourly snapshots.

| Class | Retention |
| --- | ---: |
| Frequent / hourly | 0 |
| Daily | 7 |
| Weekly | 4 |
| Monthly | 3 |
| Yearly | 0 |

Sanoid prunes its own automatically named snapshots according to both their
age and retention count. Manual snapshots are not subject to this policy.
The target is 14 automatic snapshots per protected dataset in steady state;
the actual count may temporarily differ. History accumulates after deployment;
missed past recovery points cannot be recreated.

## Scope and disk usage

The existing NAS dataset and its children are protected. The pool root,
including the cloud archive VFS cache located directly there, is not
snapshotted. A separate films dataset and its children are excluded; if
films is only a directory inside the NAS dataset, **it is included**.
ZFS snapshots operate at dataset granularity. No datasets are created,
renamed or migrated by this module. Separating films safely would require
a separately planned migration. Sanoid may log a missing films dataset
when the exclusion refers to a directory rather than a dataset.

Check the actual dataset layout and space after deployment:

```bash
sudo zfs list -r -o name,mountpoint,used,avail,usedbysnapshots myraid1
sudo zfs list -t snapshot -r -o name,creation,used -s creation myraid1
sudo zpool list myraid1
systemctl list-timers --all sanoid.timer
systemctl status sanoid.service --no-pager
sudo journalctl -u sanoid.service -n 100 --no-pager
```

The dataset's `usedbysnapshots` property measures space retained by all its
snapshots; adding individual snapshot USED values can undercount shared
blocks. If deleted or overwritten files retain too much space, reduce the
daily/weekly/monthly settings in a follow-up PR. Do not blindly destroy
snapshots or roll back an entire dataset.

## Dashboard

The existing ZFS card on the local home dashboard shows the total snapshot
count (manual and automatic) and space retained by snapshots across the
entire pool, including descendants. It sums each filesystem/volume's
`usedbysnapshots` property, not individual snapshot USED values. The
read-only metrics refresh at most once per minute; an unavailable query
is displayed as a dash, not zero.

## Recovery

For an individual file, use the read-only
`<dataset mountpoint>/.zfs/snapshot/<snapshot name>/` directory and copy
the required version to a separate recovery location before replacing
anything. A dataset rollback can discard unrelated newer changes and is
not part of the routine file-recovery procedure.

Immich media snapshots do not contain the live PostgreSQL database on the
system disk. Do not roll back the media alone as a general Immich restore.
Keep and verify the existing independent Restic backup of media plus a
database dump (see [IMMICH-MAILRU-BACKUP.md](IMMICH-MAILRU-BACKUP.md)).
Local snapshots are not protection against loss of the entire pool.
