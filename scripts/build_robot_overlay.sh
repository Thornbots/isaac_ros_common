#!/usr/bin/env bash
# Build all robot packages offline, retaining artifacts at their runtime paths.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SRC="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
WS="$(dirname "$SRC")"
[[ "$#" -eq 0 || "$*" == --check ]] || { echo 'usage: build_robot_overlay.sh [--check]' >&2; exit 2; }
if [[ "${1:-}" == --check ]]; then exec "$SCRIPT_DIR/check_robot_image.sh"; fi
mkdir "$WS/.robot-overlay.lock" || { echo 'Another overlay build is active (or stale .robot-overlay.lock).' >&2; exit 1; }
trap 'rmdir "$WS/.robot-overlay.lock"' EXIT
# Refuse to mutate symlink installs currently mounted by the robot runtime.
if [[ "$(docker inspect --format '{{.State.Running}}' thornbots-runtime 2>/dev/null || true)" == true ]]; then
    MOUNTS="$(docker inspect --format '{{range .Mounts}}{{println .Source}}{{end}}' thornbots-runtime)"
    while IFS= read -r mount; do
        case "$mount" in "$WS"|"$WS/build"|"$WS/install"|"$WS/log")
            echo 'Stop thornbots before rebuilding its active overlay (sudo systemctl stop thornbots).' >&2
            exit 1 ;;
        esac
    done <<< "$MOUNTS"
fi
rm -f "$WS/.robot-overlay-image"
IMAGE="$(cat "$WS/.robot-image")"
"$SCRIPT_DIR/check_robot_image.sh" "$IMAGE"
# A changed underlay invalidates CMake's cached dependency paths.
if [[ "$(cat "$WS/.robot-overlay-build-image" 2>/dev/null || true)" != "$IMAGE" ]]; then
    for dir in build install log; do
        if [[ -d "$WS/$dir" ]]; then find "$WS/$dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; fi
    done
fi
printf '%s\n' "$IMAGE" > "$WS/.robot-overlay-build-image"
"$SCRIPT_DIR/agent_container.sh" run "robot-overlay-$$" -w "$SRC" -p "$WS" -i "$IMAGE" -n -z -- \
    bash /workspaces/isaac_ros-dev/src/isaac_ros_common/scripts/robot_overlay_build.sh
[[ "$(cat "$WS/.robot-image")" == "$IMAGE" ]] || { echo 'Image pin changed during build; rebuild before startup.' >&2; exit 1; }
TEMP="$(mktemp "$WS/.robot-overlay-image.XXXXXXXX")"
printf '%s\n' "$IMAGE" > "$TEMP"
mv "$TEMP" "$WS/.robot-overlay-image"
echo "Offline overlay ready for $IMAGE."
