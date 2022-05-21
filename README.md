# zfs-backup
This is a backup script to replicate a ZFS filesystem and its children to
another server via zfs snapshots and `zfs send`/`zfs receive` over ssh.  It
was originally developed on Solaris 10 and now primarily on FreeBSD, but
should run with minor modification on any platform supported by ZFS.

It supplements zfs-auto-snapshot (available as part of
[zfstools](https://github.com/bdrewery/zfstools)), but runs independently.  I
prefer that snapshots continue to be taken even if the backup fails.  It does
not necessarily require that package -- anything that regularly generates
snapshots that follow a given pattern will suffice.


## Command-line options
| Option	| Description			|
| ---		| :---				|
|  -n		| debug/dry-run mode		|
|  -v		| verbose mode			|
|  -f _file_	| specify a configuration file	|
|  -r _N_	| use the Nth most recent local snapshot rather than the newest |
|  -h, -?	| display help message		|


## Basic installation
After following the prerequisites, run manually to verify
operation, and then add a line like the following to zfssnap's crontab:
```
30 * * * * /path/to/zfs-backup.sh [ options ]
```
(This for an hourly sync -- adjust accordingly if you only want to back up
daily, etc.  zfs-backup now supports command-line options and configuration
files, so you can schedule different cron jobs with different config files,
e.g. to back up to two different targets.  If you schedule multiple cron
jobs, you should use different lock files in each configuration.)

This aims to be much more robust than the backup functionality of
zfs-auto-snapshot, namely:
* it uses `zfs send -I` to send all intermediate snapshots (including
  any daily/weekly/etc.), and should still work even if it isn't run
  every hour -- as long as the newest remote snapshot hasn't been
  rotated out locally yet
* `zfs recv -dF` on the destination host removes any snapshots not
  present locally so you don't have to worry about manually removing
  old snapshots there.


## Prerequisites
1. zfs-auto-snapshot or equivalent package installed locally and regular
  snapshots enabled (e.g. hourly, daily, etc.), preferably under a limited user
  account

2. home directory set for zfssnap role (the user taking snapshots and doing
  the sending):

       # rolemod -d /path/to/home zfssnap

    (Solaris doesn't give roles a home directory by default.  Substitute an appropriate
    command for other OSes, e.g. `pw usermod` on FreeBSD.)
  
3. ssh keys set up between `zfssnap@localhost` and `remuser@remhost`:

       # su - zfssnap
       $ ssh-keygen

    Copy the contents of `.ssh/id_rsa.pub` into `~remuser/.ssh/authorized_keys` on
    remhost.  Test that key-based ssh works:

       $ ssh remuser@remhost

4. `zfs allow` done for remuser on remhost:

       # zfs allow remuser atime,create,destroy,mount,mountpoint,receive,rollback,snapshot,userprop backuppool/fs

    This can be done on a top-level filesystem, and is inherited by default.
  Depending on your usage, you may need to also allow further permissions such
  as share, sharenfs, hold, etc.  You may later revoke some of these, as receiving
  incremental snapshots doesn't require as many permissions as the initial full
  send (`create,destroy,mount,receive` is probably sufficient).

5. an initial (full) zfs send/receive done so that remhost has the fs we
  are backing up, and the associated snapshots -- something like:

       zfs send -R $POOL/$FS@zfs-auto-snap_daily-(latest) | ssh $REMUSER@$REMHOST zfs recv -dvF $REMPOOL

    Note: `zfs send -R` will send *all* snapshots associated with a dataset, so
  if you wish to purge old snapshots, do that first.

6. `zfs allow` any additional permissions needed, to fix any errors produced in step 5

7. configure the TAG/PROP/REMUSER/REMHOST/REMPOOL variables in this script or
  in a config file
  - TAG should match all snapshots of a given type when used with
    `zfs list -t snap | grep $TAG`
  - PROP is the name of the [ZFS user property](https://openzfs.github.io/openzfs-docs/man/7/zfsprops.7.html#User_Properties)
    describing the backup, if you wish to change it from the default `edu.tamu:backuptarget`.

8. `zfs set $PROP={ fullpath | basename | rootfs } pool/fs`
  on each filesystem or volume you wish to back up.  All children of `pool/fs`
  are included in the backup.

## Received properties and sharing
Filesystem properties are included in the stream sent to the remote host.  If
you have set `sharenfs` on a filesystem, the remote host will attempt to share
it using these same settings; this may fail if the sender and receiver are
different OSes, and will continue reporting a "cannot share" error every time,
even if the incremental stream does not contain any `sharenfs` settings.

To resolve this, after the initial full send/receive, set `sharenfs=off` on the
_target_ filesystem.  As long as the property is not modified again on the
sender, this will remain undisturbed.


## "Cannot unmount" a deleted filesystem
If you delete a filesystem on the source side, replicating this deletion to the
target may fail with a "cannot unmount" error, e.g.:

    cannot unmount '/export/backup/mongo': Operation not permitted
    Error sending snapshot.

This occurs on OSes where the kernel restricts mount operations, such that
granting the **mount** right with `zfs allow` is insufficient.  A simple
workaround is to run `zfs unmount `_`filesystem`_ on the target and then run
`zfs-backup.sh` again.


## Property values
Given the hierarchy `pool/a/b`,
* with **fullpath** (`zfs recv -d`), this is replicated to `backupserver:backuppool/a/b`
* with **basename** (`zfs recv -e`), this is replicated to `backupserver:backuppool/b`
  This is useful for replicating a sub-level FS into the top level of the backup pool;
  e.g. `pool/backup/foo => backuppool/foo` (instead of `backuppool/backup/foo`)
* with **rootfs** set on pool (the root filesystem in the pool; uses `zfs recv -d`
  with target set to `$REMPOOL`), pool is replicated to `backupserver:backuppool`.
  It is an error to set this property value on any child filesystem.

  WARNING: This can be dangerous -- any filesystems in $REMPOOL which do not
  exist in the source will be deleted!  For reasons of safety and simplicity,
  it is usually preferable to work with ZFS filesystems rather than the root fs,
  or use the 'fullpath' property value, which will receive a root filesystem
  into a child filesystem of the same name, otherwise replicate all children
  into top-level child filesystems, and not touch any unknown filesystems.

If this backup is not run for a long enough period that the newest
remote snapshot has been removed locally, manually run an incremental
`zfs send/recv` to bring it up to date, a la
```
  zfs send -I zfs-auto-snap_daily-(latest on remote) -R $POOL/$FS@zfs-auto-snap_daily-(latest local) |
      ssh $REMUSER@REMHOST zfs recv -dvF $REMPOOL
```
It's probably best to do a dry-run first (`zfs recv -ndvF`).

**Note:** I use daily snapshots in these manual send/recv examples because
it is less likely that the snapshot you are using will be rotated out
in the middle of a send.  Also, note that ZFS will send all snapshots for a
given filesystem before sending any for its children, rather than going in
global date order.

Alternatively, use a different tag (e.g. weekly) that still has common
snapshots, possibly in combination with the `-r` option (Nth most recent) to
avoid short-lived snapshots (e.g. hourly) being rotated out in the middle
of your sync.  This is a good use case for an alternate configuration file.


## Procedure:
  * find newest local hourly snapshot
  * find newest remote hourly snapshot (via ssh)
  * check that both `$newest_local` and `$latest_remote` snaps exist locally
  * zfs send incremental (`-I`) from `$newest_remote` to `$latest_local` to dsthost
  * if anything fails, set svc to maint. and exit
