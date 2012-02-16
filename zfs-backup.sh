#!/bin/ksh
# /usr/xpg4/bin/sh and /bin/bash also work; /bin/sh does not

# backup script to replicate a ZFS filesystem and its children to another
# server via zfs snapshots and zfs send/receive
#
# SMF manifests welcome!

# Copyright (c) 2009-12 Andrew Daugherity <adaugherity@tamu.edu>
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.


# Basic installation: After following the prerequisites, run manually to verify
# operation, and then add a line like the following to zfssnap's crontab:
# 30 * * * * /path/to/zfs-backup.sh
#
# Consult the README file for details.

# If this backup is not run for a long enough period that the newest
# remote snapshot has been removed locally, manually run an incremental
# zfs send/recv to bring it up to date, a la
#   zfs send -I zfs-auto-snap_daily-(latest on remote) -R \
#	$POOL/$FS@zfs-auto-snap_daily-(latest local) | \
#       ssh $REMUSER@REMHOST zfs recv -dvF $REMPOOL
# It's probably best to do a dry-run first (zfs recv -ndvF).


# PROCEDURE:
#   * find newest local hourly snapshot
#   * find newest remote hourly snapshot (via ssh)
#   * check that both $newest_local and $latest_remote snaps exist locally
#   * zfs send incremental (-I) from $newest_remote to $latest_local to dsthost
#   * if anything fails, set svc to maint. and exit

DEBUG=""		# set to non-null to enable debug (dry-run)
VERBOSE=""		# "-v" for verbose, null string for quiet
LOCK="/var/tmp/zfsbackup.lock"

# local pool/fs settings
POOL="mypool"
FS="myfs"
TAG="zfs-auto-snap_hourly"
# remote settings (on destination host)
REMUSER="zfsbak"
REMHOST="backupserver.my.domain"
REMPOOL="backuppool"

# begin main script
if [ -e $LOCK ]; then
    # this would be nicer as SMF maintenance state
    if [ -s $LOCK  ]; then
	# in normal mode, only send one email about the failure, not every hour
	if [ "$VERBOSE" ]; then
            echo "Service is in maintenance state; please correct and then"
            echo "rm $LOCK before running again."
        fi
    else
	# write something to the file so it will be caught by the above
	# test and cron output (and thus, emails sent) won't happen again
        echo "Maintenace mode, email has been sent once." > $LOCK
        echo "Service is in maintenance state; please correct and then"
        echo "rm $LOCK before running again."
    fi
    exit 2
fi

# allow enabling verbose mode from the command line
if [ "$1" = "-v" ]; then
    VERBOSE=$1
fi

newest_local="$(/usr/sbin/zfs list -t snapshot -H -S creation -o name -r $POOL/$FS | grep "$FS@$TAG" | head -1)"
snap2=${newest_local#*@}
[ "$DEBUG" -o "$VERBOSE" ] && echo "newest local snaphost: $snap2"

# needs public key auth configured beforehand
newest_remote="$(ssh $REMUSER@$REMHOST /usr/sbin/zfs list -t snapshot -H -S creation -o name -r $REMPOOL/$FS | grep "$FS@$TAG" | head -1)"
if [ -z $newest_remote ]; then
    echo 1>&2 "Error fetching remote snapshot listing via ssh to $REMUSER@$REMHOST."
    touch $LOCK
    exit 1
fi
snap1=${newest_remote#*@}
[ "$DEBUG" -o "$VERBOSE" ] && echo "newest remote snaphost: $snap1"

if ! /usr/sbin/zfs list -t snapshot -H $POOL/$FS@$snap1 > /dev/null 2>&1; then
    exec 1>&2
    echo "Newest hourly remote snapshot '$snap1' does not exist locally!"
    echo "Perhaps it has been already rotated out."
    echo ""
    echo "Manually run zfs send/recv to bring $REMPOOL/$FS"
    echo "on $REMHOST to a snapshot that exists on this host (newest local hourly"
    echo "snapshot is $snap2)."
    touch $LOCK
    exit 1
fi
if ! /usr/sbin/zfs list -t snapshot -H $POOL/$FS@$snap2 > /dev/null 2>&1; then
    exec 1>&2
    echo "Something has gone horribly wrong -- local snapshot $snap2"
    echo "has suddenly disappeared!"
    touch $LOCK
    exit 1
fi

if [ "$snap1" = "$snap2" ]; then
    [ $VERBOSE ] && echo "Remote snapshot is the same as local; not running."
    exit 0
fi

if [ $DEBUG ]; then
    echo "would run: /usr/sbin/zfs send -R -I $snap1 $POOL/$FS@$snap2 |"
    echo "  ssh $REMUSER@$REMHOST /usr/sbin/zfs recv -dvF $REMPOOL"
else
    if ! /usr/sbin/zfs send -R -I $snap1 $POOL/$FS@$snap2 | \
      ssh $REMUSER@$REMHOST /usr/sbin/zfs recv $VERBOSE -dF $REMPOOL; then
        echo 1>&2 "Error sending snapshot."
        touch $LOCK
        exit 1
    fi
fi

