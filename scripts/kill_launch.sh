#!/bin/bash
# Host entry point; the helper runs in the immutable target container.
set -euo pipefail
SELF="$(dirname "$(realpath "$0")")"
source "$SELF/container.sh"

usage() {
    cat <<'USAGE'
usage: kill_launch.sh -l
       kill_launch.sh <ros2-launch-or-run-pid>
       kill_launch.sh --match <literal-command-substring>
List or SIGINT only ROS launch/run trees belonging to ISAAC_ROS_CONTAINER.
Use a listed root PID or --match to stop matching trees directly; never loop
over ps output. PID 1, non-ROS roots and processes outside the container are
refused, including with --pid=host. No force override exists.
USAGE
}
if [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then usage; exit 0; fi
if ! { [ "$#" -eq 1 ] && { [ "$1" = -l ] || [[ "$1" =~ ^[0-9]+$ ]]; }; } &&
   ! { [ "$#" -eq 2 ] && [ "$1" = --match ] && [ -n "$2" ]; }; then
    usage >&2; exit 2
fi
TARGET="$(docker inspect -f '{{.Id}}' "$CONTAINER" 2>/dev/null)" || {
    echo "kill_launch.sh: container '$CONTAINER' not found" >&2; exit 1;
}
if ! container_running "$TARGET"; then
    echo "kill_launch.sh: container '$CONTAINER' is not running" >&2; exit 1
fi
# stdin transports the helper without assuming this checkout's container path.
docker exec -i -u "$CONTAINER_USER" "$TARGET" python3 - "$@" < "$SELF/kill_launch.py"
