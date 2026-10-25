#!/usr/bin/env bash
# Mac/Colima integration: own containers only; no physical robot operations.
set -euo pipefail
SELF="$(cd "$(dirname "$0")/../scripts" && pwd)"
export DOCKER_HOST="${DOCKER_HOST:-unix://$HOME/.colima/default/docker.sock}"
TEMP="$(mktemp -d /tmp/launch-scope.XXXXXXXX)"
TASK="launch-scope-$$"
PEER="launch-peer-$$"
REAL_DOCKER="$(command -v docker)"
export REAL_DOCKER
cleanup() {
    PATH="$ORIGINAL_PATH" "$SELF/agent_container.sh" down "$TASK" || true
    "$SELF/agent_container.sh" down "$PEER" || true
    rm -rf "$TEMP"
}
ORIGINAL_PATH="$PATH"
trap cleanup EXIT
mkdir -p "$TEMP/peer/isaac_ros_common" "$TEMP/target/isaac_ros_common"
"$SELF/agent_container.sh" up "$PEER" -w "$TEMP/peer"
PEER_CONTAINER="isaac-agent-$PEER"
docker cp "$SELF/../tests/stop_fixture.launch.py" "$PEER_CONTAINER:/tmp/foreign.launch.py"
ISAAC_ROS_CONTAINER="$PEER_CONTAINER" "$SELF/dexec.sh" -d -- ros2 launch /tmp/foreign.launch.py
wait_file() {
    local i
    for i in $(seq 1 100); do
        docker exec "$ISAAC_ROS_CONTAINER" test -f "$1" && return
        sleep .1
    done
    echo "timed out: $1" >&2; return 1
}
export ISAAC_ROS_CONTAINER="$PEER_CONTAINER"
wait_file /tmp/kill-launch-ready
for mode in private host; do
    if [ "$mode" = host ]; then
        # Export a function: agent_container.sh prepends Homebrew to PATH.
        docker() {
            if [ "${1:-}" = run ]; then
                shift
                "$REAL_DOCKER" run --pid=host --cgroupns=host "$@"
            else "$REAL_DOCKER" "$@"; fi
        }
        export -f docker
    fi
    "$SELF/agent_container.sh" up "$TASK" -w "$TEMP/target"
    export ISAAC_ROS_CONTAINER="isaac-agent-$TASK"
    actual="$(docker inspect -f '{{.HostConfig.PidMode}}' "$ISAAC_ROS_CONTAINER")"
    if [ "$mode" = host ]; then [ "$actual" = host ]; else [ -z "$actual" ]; fi
    docker inspect -f 'PID mode={{.HostConfig.PidMode}} cgroupns={{.HostConfig.CgroupnsMode}}' "$ISAAC_ROS_CONTAINER"
    docker cp "$SELF/../tests/stop_fixture.launch.py" "$ISAAC_ROS_CONTAINER:/tmp/owned.launch.py"
    for selector in pid match; do
        docker exec "$ISAAC_ROS_CONTAINER" rm -f /tmp/kill-launch-ready /tmp/kill-launch-stopped
        "$SELF/dexec.sh" -d -- ros2 launch /tmp/owned.launch.py
        wait_file /tmp/kill-launch-ready
        listing="$("$SELF/kill_launch.sh" -l)"
        echo "$listing"
        [ "$(printf '%s\n' "$listing" | wc -l | tr -d ' ')" = 2 ]
        pid="$(printf '%s\n' "$listing" | awk 'NR==2 {print $1}')"
        [[ "$pid" =~ ^[0-9]+$ ]]
        if "$SELF/kill_launch.sh" 1; then exit 1; fi
        if "$SELF/kill_launch.sh" --match dockerd; then exit 1; fi
        # In host mode this is not PID 1: reject the target's own init/sleep too.
        if [ "$mode" = host ]; then
            init="$(docker inspect -f '{{.State.Pid}}' "$ISAAC_ROS_CONTAINER")"
            if "$SELF/kill_launch.sh" "$init"; then exit 1; fi
            docker exec "$ISAAC_ROS_CONTAINER" test -d "/proc/$init"
        fi
        if "$SELF/kill_launch.sh" --match foreign.launch.py; then exit 1; fi
        if "$SELF/kill_launch.sh" -f "$pid"; then exit 1; fi
        if [ "$mode" = host ]; then
            # dockerd and the other container's real ROS tree are visible but foreign.
            foreign="$(docker exec "$ISAAC_ROS_CONTAINER" pgrep -f '^/usr/bin/python3 /opt/ros/jazzy/bin/ros2 launch /tmp/foreign.launch.py$')"
            daemon="$(docker exec "$ISAAC_ROS_CONTAINER" pgrep -x dockerd | head -1)"
            [ -n "$foreign" ] && [ -n "$daemon" ]
            for outside in "$foreign" "$daemon"; do
                if "$SELF/kill_launch.sh" "$outside"; then exit 1; fi
                docker exec "$ISAAC_ROS_CONTAINER" test -d "/proc/$outside"
            done
        fi
        if [ "$selector" = pid ]; then "$SELF/kill_launch.sh" "$pid"
        else "$SELF/kill_launch.sh" --match owned.launch.py; fi
        wait_file /tmp/kill-launch-stopped
        for i in $(seq 1 100); do
            if ! "$SELF/kill_launch.sh" -l | grep -q owned.launch.py; then break; fi
            sleep .1
        done
        ! "$SELF/kill_launch.sh" -l | grep -q owned.launch.py
        docker exec "$PEER_CONTAINER" test ! -f /tmp/kill-launch-stopped
        echo "PASS $mode/$selector: owned ROS tree stopped cleanly; foreign ROS tree alive"
    done
    PATH="$ORIGINAL_PATH" "$SELF/agent_container.sh" down "$TASK"
    if [ "$mode" = host ]; then unset -f docker; fi
    export PATH="$ORIGINAL_PATH"
done
# Stop the peer through the same guarded interface before removing it.
ISAAC_ROS_CONTAINER="$PEER_CONTAINER" "$SELF/kill_launch.sh" --match foreign.launch.py
