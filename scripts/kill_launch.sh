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
# Usage: kill_launch.sh <ros2-launch-pid>
#   Find the PID first with, e.g.:
#     ./dexec.sh -- ps aux | grep "ros2 launch" | grep -v grep
#
# Set ISAAC_ROS_CONTAINER to override the container name (default
# isaac_ros_dev-x86_64-container).
set -euo pipefail

if [ "${1:-}" = "" ]; then
    echo "usage: kill_launch.sh <ros2-launch-pid>" >&2
    exit 2
fi

LAUNCH_PID="$1"
CONTAINER="${ISAAC_ROS_CONTAINER:-isaac_ros_dev-x86_64-container}"

# -u admin + bash -c matters here, not just cosmetic: `docker exec
# CONTAINER kill -SIGINT -PGID` as raw argv (no shell, no -u) was found to
# silently fail to deliver the signal in testing, even though it looked
# like it ran; going through bash -c as the admin user (matching how the
# target process itself was started) is the form actually verified to
# work.
PGID=$(docker exec -u admin "$CONTAINER" bash -c "ps -o pgid= -p $LAUNCH_PID" | tr -d ' ')
if [ -z "$PGID" ]; then
    echo "kill_launch.sh: no such PID $LAUNCH_PID in $CONTAINER" >&2
    exit 1
fi

echo "Sending SIGINT to process group $PGID (from launch PID $LAUNCH_PID)..."
docker exec -u admin "$CONTAINER" bash -c "kill -SIGINT -$PGID"
