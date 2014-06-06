#!/bin/ksh
# /usr/xpg4/bin/sh and /bin/bash also work; /bin/sh does not

# backup script to replicate a ZFS filesystem and its children to another
# server via zfs snapshots and zfs send/receive
#
# SMF manifests welcome!
#
# v0.3 - cmdline options and cfg file support
# v0.2 - multiple datasets
# v0.1 - initial working version

# Copyright (c) 2009-13 Andrew Daugherity <adaugherity@tamu.edu>
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

# all of the following variables (except CFG) may be set in the config file
DEBUG=""		# set to non-null to enable debug (dry-run)
VERBOSE=""		# "-v" for verbose, null string for quiet
LOCK="/var/tmp/zfsbackup.lock"
PID="/var/tmp/zfsbackup.pid"
CFG="/var/lib/zfssnap/zfs-backup.cfg"
ZFS="/usr/sbin/zfs"

# local settings -- datasets to back up are now found by property
TAG="zfs-auto-snap_daily"
PROP="edu.tamu:backuptarget"
# remote settings (on destination host)
REMUSER="zfsbak"
# special case: when $REMHOST=localhost, ssh is bypassed
REMHOST="backupserver.my.domain"
REMPOOL="backuppool"
REMZFS="/usr/sbin/zfs"


usage() {
    echo "Usage: $(basename $0) [ -nv ] [-r N ] [ [-f] cfg_file ]"
    echo "  -n\t\tdebug (dry-run) mode"
    echo "  -v\t\tverbose mode"
    echo "  -f\t\tspecify a configuration file"
    echo "  -r N\t\tuse the Nth most recent snapshot instead of the newest"
    echo "If the configuration file is last option specified, the -f flag is optional."
    exit 1
}
# simple ordinal function, does not validate input
ord() {
    case $1 in
        1|*[0,2-9]1) echo "$1st";;
        2|*[0,2-9]2) echo "$1nd";;
        3|*[0,2-9]3) echo "$1rd";;
        *1[123]|*[0,4-9]) echo "$1th";;
        *) echo $1;;
    esac
}

# Option parsing
set -- $(getopt h?nvf:r: $*)
if [ $? -ne 0 ]; then
    usage
fi
for opt; do
    case $opt in
	-h|-\?) usage;;
	-n) dbg_flag=Y; shift;;
	-v) verb_flag=Y; shift;;
	-f) CFG=$2; shift 2;;
	-r) recent_flag=$2; shift 2;;
	--) shift; break;;
    esac
done
if [ $# -gt 1 ]; then
    usage
elif [ $# -eq 1 ]; then
    CFG=$1
fi
# If file is in current directory, add ./ to make sure the correct file is sourced
if [ $(basename $CFG) = "$CFG" ]; then
    CFG="./$CFG"
fi
# Read any settings from a config file, if present
if [ -r $CFG ]; then
    . $CFG
fi
# Set options now, so cmdline opts override the cfg file
[ "$dbg_flag" ] && DEBUG=1
[ "$verb_flag" ] && VERBOSE="-v"
[ "$recent_flag" ] && RECENT=$recent_flag
# set default value so integer tests work
if [ -z "$RECENT" ]; then RECENT=0; fi
# local (non-ssh) backup handling: REMHOST=localhost
if [ "$REMHOST" = "localhost" ]; then
    REMZFS_CMD="$ZFS"
else
    REMZFS_CMD="ssh $REMUSER@$REMHOST $REMZFS"
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

    if [ $RECENT -gt 1 ]; then
	newest_local="$($ZFS list -t snapshot -H -S creation -o name -d 1 $DATASET | grep $TAG | awk NR==$RECENT)"
	if [ -z "$newest_local" ]; then
	    echo "Error: could not find $(ord $RECENT) most recent snapshot matching tag" >&2
	    echo "'$TAG' for ${DATASET}!" >&2
	    return 1
	fi
	msg="using local snapshot ($(ord $RECENT) most recent):"
    else
	newest_local="$($ZFS list -t snapshot -H -S creation -o name -d 1 $DATASET | grep $TAG | head -1)"
	if [ -z "$newest_local" ]; then
	    echo "Error: no snapshots matching tag '$TAG' for ${DATASET}!" >&2
	    return 1
	fi
	msg="newest local snapshot:"
    fi
    snap2=${newest_local#*@}
    [ "$DEBUG" -o "$VERBOSE" ] && echo "$msg $snap2"

    if [ "$REMHOST" = "localhost" ]; then
	newest_remote="$($ZFS list -t snapshot -H -S creation -o name -d 1 $TARGET | grep $TAG | head -1)"
	err_msg="Error fetching snapshot listing for local target pool $REMPOOL."
    else
	# ssh needs public key auth configured beforehand
	# Not using $REMZFS_CMD because we need 'ssh -n' here, but must not use
	# 'ssh -n' for the actual zfs recv.
	newest_remote="$(ssh -n $REMUSER@$REMHOST $REMZFS list -t snapshot -H -S creation -o name -d 1 $TARGET | grep $TAG | head -1)"
	err_msg="Error fetching remote snapshot listing via ssh to $REMUSER@$REMHOST."
    fi
    if [ -z $newest_remote ]; then
	echo "$err_msg" >&2
	[ $DEBUG ] || touch $LOCK
	return 1
    fi
    snap1=${newest_remote#*@}
    [ "$DEBUG" -o "$VERBOSE" ] && echo "newest remote snapshot: $snap1"

    if ! $ZFS list -t snapshot -H $DATASET@$snap1 > /dev/null 2>&1; then
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
    if ! $ZFS list -t snapshot -H $DATASET@$snap2 > /dev/null 2>&1; then
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

    # sanity checking of snapshot times -- avoid going too far back with -r
    snap1time=$($ZFS get -Hp -o value creation $DATASET@$snap1)
    snap2time=$($ZFS get -Hp -o value creation $DATASET@$snap2)
    if [ $snap2time -lt $snap1time ]; then
	echo "Error: target snapshot $snap2 is older than $snap1!"
	echo "Did you go too far back with '-r'?"
	return 1
    fi

    if [ $DEBUG ]; then
	echo "would run: $ZFS send -R -I $snap1 $DATASET@$snap2 |"
	echo "  $REMZFS_CMD recv $RECV_OPT -vF $REMPOOL"
    else
	if ! pfexec $ZFS send -R -I $snap1 $DATASET@$snap2 | \
	  $REMZFS_CMD recv $VERBOSE $RECV_OPT -F $REMPOOL; then
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
	# in normal mode, only send one email about the failure, not every run
	if [ "$VERBOSE" ]; then
            echo "Service is in maintenance state; please correct and then"
            echo "rm $LOCK before running again."
        fi
    else
	# write something to the file so it will be caught by the above
	# test and cron output (and thus, emails sent) won't happen again
        echo "Maintenance mode, email has been sent once." > $LOCK
        echo "Service is in maintenance state; please correct and then"
        echo "rm $LOCK before running again."
    fi
    exit 2
fi

if [ -e "$PID" ]; then
    [ "$VERBOSE" ] && echo "Backup job already running!"
    exit 0
fi
echo $$ > $PID

FAIL=0
# get the datasets that have our backup property set
COUNT=$($ZFS get -s local -H -o name,value $PROP | wc -l)
if [ $COUNT -lt 1 ]; then
    echo "No datasets configured for backup!  Please set the '$PROP' property"
    echo "appropriately on the datasets you wish to back up."
    rm $PID
    exit 2
fi
$ZFS get -s local -H -o name,value $PROP |
while read dataset value
do
    case $value in
    # property values:
    #   Given the hierarchy pool/a/b,
    #   * fullpath: replicate to backuppool/a/b
    #   * basename: replicate to backuppool/b
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

rm $PID
exit $FAIL
