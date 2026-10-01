#!/bin/bash
# setup_workspace.sh: link this repo's isaac-ros-cli config to where the CLI
# looks for it. Run on the host once per clone; safe to re-run.
#   <ws>/scripts                          -> src/isaac_ros_common/scripts
#   <ws>/.isaac-ros-cli                   -> src/isaac_ros_common/.isaac-ros-cli
#   <ws>/../scripts/.build_image_layers.yaml -> src/isaac_ros_common/scripts/...
# <ws> is the workspace this script sits in, whatever ISAAC_ROS_WS says. The
# last link is outside <ws> because the CLI reads that file only there, so
# sibling workspaces share it: re-run from the workspace you build.
set -euo pipefail

REPO="$(realpath "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/..")"
WS="$(realpath "$REPO/../..")"

link() {  # link <target> <link-path>
    if [ -e "$2" ] && [ ! -L "$2" ]; then
        echo "setup_workspace.sh: $2 exists and is not a symlink; move it aside" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$2")"
    # Relative, like GNU ln -r (BSD ln on the Mac has no -r).
    ln -sfn "$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))' "$1" "$2")" "$2"
    echo "  $2 -> $(readlink "$2")"
}

link "$REPO/scripts" "$WS/scripts"
link "$REPO/.isaac-ros-cli" "$WS/.isaac-ros-cli"
link "$REPO/scripts/.build_image_layers.yaml" "$(dirname "$WS")/scripts/.build_image_layers.yaml"

# The CLI checks <ws>/../scripts/ before <ws>/scripts/, so a config there wins.
if [ -e "$(dirname "$WS")/scripts/.isaac_ros_common-config" ]; then
    echo "setup_workspace.sh: warning: $(dirname "$WS")/scripts/.isaac_ros_common-config" \
         "shadows ours; remove it" >&2
fi
if [ "${ISAAC_ROS_WS:-}" != "$WS" ]; then
    echo "Run the CLI with ISAAC_ROS_WS=$WS (currently '${ISAAC_ROS_WS:-}')."
fi
