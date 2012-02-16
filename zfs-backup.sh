#!/bin/ksh
# /usr/xpg4/bin/sh and /bin/bash also work; /bin/sh does not

# backup script to replicate a ZFS filesystem and its children to another
# server via zfs snapshots and zfs send/receive
#
# SMF manifests welcome!
# v0.2 - multiple datasets

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

DEBUG="1"		# set to non-null to enable debug (dry-run)
VERBOSE="-v"		# "-v" for verbose, null string for quiet
LOCK="/var/tmp/zfsbackup.lock"
CFG="./zfs-backup.cfg"

# local settings -- datasets to back up are now found by property
TAG="zfs-auto-snap_daily"
PROP="edu.tamu:backuptarget"
# remote settings (on destination host)
REMUSER="zfsbak"
REMHOST="backupserver.my.domain"
REMPOOL="backuppool"

# Read any settings from a config file, if present
if [ -r $CFG ]; then
    . $CFG
fi

# Usage: do_backup pool/fs/to/backup receive_option
#   receive_option should be -d for full path and -e for base name
#   See the descriptions in the 'zfs receive' section of zfs(1M) for more details.
do_backup() {

    DATASET=$1
    FS=${DATASET#*/}		# strip local pool name
    FS_BASE=${DATASET##*/}	# only the last part
    RECV_OPT=$2

    case $RECV_OPT in
	-e)	TARGET="$REMPOOL/$FS_BASE"
		;;
	-d)	TARGET="$REMPOOL/$FS"
		;;
	*)	BAD=1
    esac
    if [ $# -ne 2 -o "$BAD" ]; then
	echo "Oops! do_backup called improperly:" 1>&2
	echo "    $*" 1>&2
	return 2
    fi

    newest_local="$(/usr/sbin/zfs list -t snapshot -H -S creation -o name -d 1 $DATASET | grep $TAG | head -1)"
    snap2=${newest_local#*@}
    [ "$DEBUG" -o "$VERBOSE" ] && echo "newest local snapshot: $snap2"

    # needs public key auth configured beforehand
    newest_remote="$(ssh $REMUSER@$REMHOST /usr/sbin/zfs list -t snapshot -H -S creation -o name -d 1 $TARGET | grep $TAG | head -1)"
    if [ -z $newest_remote ]; then
	echo "Error fetching remote snapshot listing via ssh to $REMUSER@$REMHOST." >&2
	[ $DEBUG ] || touch $LOCK
	return 0
    fi
    snap1=${newest_remote#*@}
    [ "$DEBUG" -o "$VERBOSE" ] && echo "newest remote snapshot: $snap1"

    if ! /usr/sbin/zfs list -t snapshot -H $DATASET@$snap1 > /dev/null 2>&1; then
	exec 1>&2
	echo "Newest remote snapshot '$snap1' does not exist locally!"
	echo "Perhaps it has been already rotated out."
	echo ""
	echo "Manually run zfs send/recv to bring $TARGET on $REMHOST"
	echo "to a snapshot that exists on this host (newest local snapshot with the"
	echo "tag $TAG is $snap2)."
	[ $DEBUG ] || touch $LOCK
	return 1
    fi
return 0
    if ! /usr/sbin/zfs list -t snapshot -H $DATASET@$snap2 > /dev/null 2>&1; then
	exec 1>&2
	echo "Something has gone horribly wrong -- local snapshot $snap2"
	echo "has suddenly disappeared!"
	[ $DEBUG ] || touch $LOCK
	return 1
    fi

    if [ "$snap1" = "$snap2" ]; then
	[ $VERBOSE ] && echo "Remote snapshot is the same as local; not running."
	return 0
    fi

    if [ $DEBUG ]; then
	echo "would run: /usr/sbin/zfs send -R -I $snap1 $DATASET@$snap2 |"
	echo "  ssh $REMUSER@$REMHOST /usr/sbin/zfs recv $RECV_OPT -vF $REMPOOL"
    else
	if ! /usr/sbin/zfs send -R -I $snap1 $DATASET@$snap2 | \
	  ssh $REMUSER@$REMHOST /usr/sbin/zfs recv $VERBOSE $RECV_OPT -F $REMPOOL; then
	    echo 1>&2 "Error sending snapshot."
	    touch $LOCK
	    return 1
	fi
    fi
}

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

FAIL=0
# get the datasets that have our backup property set
/usr/sbin/zfs get -s local -H -o name,value $PROP | \
while read dataset value
do
    case $value in
	fullpath) [ $VERBOSE ] && echo "\n$dataset:"
	    do_backup $dataset -d
		;;
	basename) [ $VERBOSE ] && echo "\n$dataset:"
	    do_backup $dataset -e
		;;
	*)  echo "Warning: $dataset has invalid backuptarget property '$value', skipping." >&2
		;;
    esac
    STATUS=$?
    if [ $STATUS -gt 0 ]; then
	FAIL=$(($FAIL | $STATUS))
    fi
done

if [ $FAIL -gt 0 ]; then
    if [ $(($FAIL & 1)) -gt 0 ]; then
	echo "There were errors backing up some datasets." >&2
    fi
    if [ $(($FAIL & 2)) -gt 0 ]; then
	echo "Some datasets had misconfigured $PROP properties." >&2
    fi
fi

exit $FAIL
