#!/bin/bash
# dexec.sh -- run a command inside the running isaac_ros_dev container with
# the DDS/ROS environment a real interactive shell gets (ROS_DOMAIN_ID,
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
# ONE DELIBERATE DIFFERENCE FROM THE USER'S TERMINAL -- package resolution.
# /etc/bash.bashrc ends by sourcing ONLY /workspaces/ros2_ws/install, so an
# interactive shell resolves a package present in both workspaces to the
# image-baked GitHub clone. dexec.sh also sources
# /workspaces/isaac_ros-dev/install afterward, which prepends it, so here
# the locally-built copy (the bind-mounted src/ edit) wins instead --
# measured 2026-07-26: isaac_ros-dev at AMENT_PREFIX_PATH position 3,
# ros2_ws at 24. Packages NOT built locally (e.g. sllidar_ros2) still fall
# through to ros2_ws. Net effect: the same `ros2 launch` can run different
# code here than in the user's terminal. Always run `ros2 pkg prefix <pkg>`
# through the SAME entry point you will launch from -- see DOCKER.md's
# "Two workspaces" section.
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

# Preflight: `docker exec` against a stopped/absent container fails with a
# raw daemon error that doesn't say what to do about it. Note this script
# never starts or builds anything itself -- launching the container is the
# user's call (see the skill's "Never build the image yourself" note).
if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
    echo "dexec.sh: container '$CONTAINER' is not running." >&2
    echo "  Ask the user to start it:  cd isaac_ros_common/scripts && ./run_dev.sh" >&2
    echo "  (or set ISAAC_ROS_CONTAINER if the name differs)" >&2
    exit 1
fi

# printf %q (not "$*") -- "$*" space-joins argv into a flat string, which
# loses each argument's original boundaries once it's re-parsed by the
# inner `bash -lc` below. That's silently fine for a simple argv like
# `python3 script.py --backend slam`, but breaks the moment any argument
# itself needs to carry shell syntax -- e.g. wrapping in `bash -c "... >
# out.log 2>&1"` to add custom redirection on top of dexec.sh's own
# -- the embedded quotes/redirects get flattened away, `bash -c` ends up
# only seeing its first *word* as the script (everything else becomes
# stray positional params), and the process silently exits immediately
# with empty output and no error. Hit exactly this running the
# localization test bench in the background (2026-07-23) -- diagnosed via
# empty /tmp/dexec_*.log + `ps aux` showing nothing running. `printf %q`
# re-escapes each argument so it survives the round trip through the
# inner shell as exactly one token, so callers don't need to avoid
# spaces/quotes/redirects in their command; it also means you should NOT
# add your own `> file 2>&1` wrapper for -d launches -- dexec.sh already
# redirects to /tmp/dexec_$$.log for you (see below).
CMD="$(printf '%q ' "$@")"

# The whole env setup is grouped with stdout sent to /dev/null (stderr is
# kept, so a genuine sourcing error still surfaces). Ubuntu's
# /etc/bash.bashrc ends with a "To run a command as administrator (user
# \"root\")..." sudo hint that prints on *every* interactive-guard-passing
# source, on STDOUT -- without this redirect those two lines are prepended
# to the output of every command, so host-side captures like
# `X=$(dexec.sh -- ros2 pkg prefix foo)` come back with banner text glued
# onto the value. Verified 2026-07-26.
SOURCE_ENV="{ export PS1='\$ ' && source /etc/bash.bashrc && source /workspaces/ros2_ws/install/setup.bash && source /workspaces/isaac_ros-dev/install/setup.bash ; } >/dev/null"

if [ "$DETACH" -eq 1 ]; then
    # $$ is the HOST shell's pid, expanded here before the string is sent
    # into the container -- so LOG is exactly the path used inside, and can
    # be reported from here. It has to be reported from here: `docker exec
    # -d` detaches immediately and discards the inner command's stdout, so
    # an `echo` on the container side (as this used to do) is never seen by
    # the caller.
    LOG="/tmp/dexec_$$.log"
    # setsid so the whole launch tree shares one process group, separate
    # from this docker exec's own -- kill_launch.sh needs that to clean up
    # the entire tree with one SIGINT instead of missing orphaned children.
    docker exec -d -u "$USERNAME" --workdir "$WORKDIR" "$CONTAINER" \
        bash -lc "$SOURCE_ENV && setsid nohup $CMD > $LOG 2>&1 < /dev/null & disown"
    echo "started detached in $CONTAINER (log: $LOG)"
    echo "  read it with:  $0 -- cat $LOG"
    echo "  find the launch pid:  $(dirname "$0")/kill_launch.sh -l"
    echo "  stop it with:  $(dirname "$0")/kill_launch.sh <launch-pid>"
else
    # -i so piped stdin reaches the command (`echo x | dexec.sh -- cat`);
    # without it docker exec closes stdin and the command silently sees EOF.
    # Trade-off: a command that prompts now WAITS instead of failing fast on
    # EOF, and a dexec.sh call inside a `while read ... done < file` loop
    # will consume the loop's input. Append `< /dev/null` for either case.
    exec docker exec -i -u "$USERNAME" --workdir "$WORKDIR" "$CONTAINER" \
        bash -lc "$SOURCE_ENV && $CMD"
fi
