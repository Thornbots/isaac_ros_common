#!/bin/bash
# dexec.sh -- run a command inside the running isaac_ros_dev container with
# the same environment a real interactive shell gets (ROS_DOMAIN_ID,
# RMW_IMPLEMENTATION, FASTRTPS profile via /etc/bash.bashrc) plus both
# workspace installs sourced (/workspaces/ros2_ws for image-baked packages
# like sllidar_ros2/rf2o_laser_odometry/robot_localization, and
# /workspaces/isaac_ros-dev for this repo's own packages like
# sentry_pkg/sim).
#
# Exists because `docker exec ... bash -lc "source /etc/bash.bashrc && ..."`
# silently does nothing on its own -- that file starts with
# `[ -z "$PS1" ] && return`, an interactive-shell-only guard -- so PS1 has
# to be set first, and it's easy to forget one of the two workspace
# sources too. A `docker exec` session that skips this can look completely
# healthy while missing real config, which caused real debugging pain
# earlier in this project (see DOCKER.md's "Any docker exec running ROS
# commands..." note for the full story).
#
# Usage:
#   dexec.sh [-r] [-d] [-w WORKDIR] -- <command...>
#   -r        run as root instead of admin (needed for apt-get etc.)
#   -d        detach (docker exec -d) -- for launches you want left running;
#             wrapped in `setsid` so the launch becomes its own process
#             group leader, letting kill_launch.sh clean it up properly
#             later (see that script for why this matters)
#   -w DIR    override workdir (default /workspaces/isaac_ros-dev)
#
# Set ISAAC_ROS_CONTAINER to override the container name (default
# isaac_ros_dev-x86_64-container).
#
# Examples:
#   ./dexec.sh -- ros2 topic list
#   ./dexec.sh -d -- ros2 launch sim sim.launch.py
#   ./dexec.sh -r -- apt-get install -y ros-humble-foo
set -euo pipefail

CONTAINER="${ISAAC_ROS_CONTAINER:-isaac_ros_dev-x86_64-container}"
USERNAME="admin"
WORKDIR="/workspaces/isaac_ros-dev"
DETACH=0

usage() {
    echo "usage: dexec.sh [-r] [-d] [-w WORKDIR] -- <command...>" >&2
    exit 2
}

while getopts "rdw:" opt; do
    case "$opt" in
        r) USERNAME="root" ;;
        d) DETACH=1 ;;
        w) WORKDIR="$OPTARG" ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

if [ "${1:-}" = "--" ]; then
    shift
fi

if [ "$#" -eq 0 ]; then
    usage
fi

CMD="$*"
SOURCE_ENV="export PS1='\$ ' && source /etc/bash.bashrc && source /workspaces/ros2_ws/install/setup.bash && source /workspaces/isaac_ros-dev/install/setup.bash"

if [ "$DETACH" -eq 1 ]; then
    # setsid so the whole launch tree shares one process group, separate
    # from this docker exec's own -- kill_launch.sh needs that to clean up
    # the entire tree with one SIGINT instead of missing orphaned children.
    exec docker exec -d -u "$USERNAME" --workdir "$WORKDIR" "$CONTAINER" \
        bash -lc "$SOURCE_ENV && setsid nohup $CMD > /tmp/dexec_$$.log 2>&1 < /dev/null & disown; echo \"started (log: /tmp/dexec_$$.log)\""
else
    exec docker exec -u "$USERNAME" --workdir "$WORKDIR" "$CONTAINER" \
        bash -lc "$SOURCE_ENV && $CMD"
fi
