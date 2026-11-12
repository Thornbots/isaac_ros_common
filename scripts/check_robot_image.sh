#!/usr/bin/env bash
# Offline dependency check; an explicit immutable ID is used by the pull helper.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SRC="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
WS="$(dirname "$SRC")"
IMAGE="${1:-$(cat "$WS/.robot-image")}"
[[ "$IMAGE" =~ ^sha256:[a-f0-9]{64}$ ]] || { echo 'Missing/invalid .robot-image; run pull_robot_image.sh.' >&2; exit 1; }
exec "$SCRIPT_DIR/agent_container.sh" run "robot-check-$$" -w "$SRC" -r -i "$IMAGE" -n -z -- \
    python3 /workspaces/isaac_ros-dev/src/isaac_ros_common/scripts/robot_image_contract.py
