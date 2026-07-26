#!/bin/bash
# kill_launch.sh -- cleanly stop a `ros2 launch` tree started via
# `dexec.sh -d` (or any backgrounded ros2 launch without a controlling TTY).
#
# Backgrounded `ros2 launch` processes started this way don't reliably
# forward SIGINT to their child nodes from the launch PID alone -- this
# bit multiple sessions in this project. Sending SIGINT to the launch
# process's own process group (negative PID) is what actually propagates
# cleanly to every child node. Never use pkill/killall here: a partial
# kill that leaves orphaned children running alongside a fresh relaunch
# causes duplicate-node TF jitter (see SESSION_NOTES.md, "Killing ROS
# launches correctly").
#
# Usage:
#   kill_launch.sh -l              list running launch trees + their PIDs
#   kill_launch.sh <launch-pid>    SIGINT that tree's whole process group
#   kill_launch.sh -f <pid>        skip the group-leader safety check
#
# Use -l to find the PID. Do NOT pick it out of
# `ps aux | grep "ros2 launch"` (which this script's docs used to
# recommend): that also matches dexec.sh's own `bash -lc` wrapper, whose
# command line contains the full launch string. Passing the wrapper's PID
# kills the wrapper's process group and leaves the actual launch tree
# running, with a "Sending SIGINT..." message that looks like it worked --
# reproduced 2026-07-26. Hence the pid==pgid check below.
#
# Set ISAAC_ROS_CONTAINER to override the container name (default
# isaac_ros_dev-x86_64-container).
set -euo pipefail

CONTAINER="${ISAAC_ROS_CONTAINER:-isaac_ros_dev-x86_64-container}"
FORCE=0
LIST=0

usage() {
    echo "usage: kill_launch.sh [-l] [-f] <ros2-launch-pid>" >&2
    echo "       kill_launch.sh -l    # list candidate launch trees" >&2
    exit 2
}

# Same preflight as dexec.sh -- without it a stopped container produces a
# raw daemon error. Starting the container is the user's call, never ours.
if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
    echo "kill_launch.sh: container '$CONTAINER' is not running" \
         "(so nothing is left to kill)." >&2
    exit 1
fi

while getopts "lf" opt; do
    case "$opt" in
        l) LIST=1 ;;
        f) FORCE=1 ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

# A tree started by `dexec.sh -d` is setsid'd, so its root satisfies
# pid == pgid == sid. That also matches launches started from the user's
# own terminal, and excludes both the container's init (pid 1) and the
# transient shell running this very ps.
LIST_CMD="ps -eo pid,pgid,sid,ppid,etime,cmd --sort=pid \
    | awk 'NR==1 || (\$1==\$2 && \$1==\$3 && \$1!=1)' \
    | grep -v 'ps -eo pid,pgid'"

if [ "$LIST" -eq 1 ]; then
    docker exec -u admin "$CONTAINER" bash -c "$LIST_CMD"
    exit 0
fi

if [ "$#" -ne 1 ]; then
    usage
fi
LAUNCH_PID="$1"

# Reject anything that isn't a single integer up front: a multi-line or
# space-separated argument (easy to produce by capturing the output of a
# grep that matched more than one line) otherwise gets interpolated
# straight into the `ps`/`kill` command strings below, where it silently
# resolves to the wrong process group.
if ! [[ "$LAUNCH_PID" =~ ^[0-9]+$ ]]; then
    echo "kill_launch.sh: expected a single numeric PID, got: '$LAUNCH_PID'" >&2
    echo "  list candidates with:  $0 -l" >&2
    exit 2
fi

# -u admin + bash -c matters here, not just cosmetic: `docker exec
# CONTAINER kill -SIGINT -PGID` as raw argv (no shell, no -u) was found to
# silently fail to deliver the signal in testing, even though it looked
# like it ran; going through bash -c as the admin user (matching how the
# target process itself was started) is the form actually verified to
# work.
#
# `|| true` is load-bearing under `set -e`: `ps -o pgid= -p <gone-pid>`
# exits nonzero, which aborted the whole script at this assignment and made
# the friendly message below unreachable -- a bogus PID exited 1 with no
# output at all. Verified 2026-07-26.
read -r PGID SID <<<"$(docker exec -u admin "$CONTAINER" \
    bash -c "ps -o pgid=,sid= -p $LAUNCH_PID" 2>/dev/null | tr -s ' ' || true)"
if [ -z "${PGID:-}" ]; then
    echo "kill_launch.sh: no such PID $LAUNCH_PID in $CONTAINER" >&2
    echo "  list candidates with:  $0 -l" >&2
    exit 1
fi

if [ "$FORCE" -eq 0 ] && { [ "$PGID" != "$LAUNCH_PID" ] || [ "${SID:-}" != "$LAUNCH_PID" ]; }; then
    echo "kill_launch.sh: PID $LAUNCH_PID is not the root of a launch tree" \
         "(its pgid=$PGID, sid=${SID:-?})." >&2
    echo "  This usually means the PID came from a grep that matched" \
         "dexec.sh's bash -lc wrapper instead of the launch itself." >&2
    echo "  Signalling group $PGID would leave the real tree running." >&2
    echo "  List real candidates:  $0 -l    (or re-run with -f to override)" >&2
    exit 1
fi

echo "Sending SIGINT to process group $PGID (from launch PID $LAUNCH_PID)..."
docker exec -u admin "$CONTAINER" bash -c "kill -SIGINT -$PGID"
