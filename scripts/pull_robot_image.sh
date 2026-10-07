#!/usr/bin/env bash
# Pull the image for this exact workspace; retag it for isaac-ros-cli.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"
REVISION="$(git -C "$WORKSPACE_SRC" rev-parse HEAD)"
REGISTRY_TAG="ghcr.io/thornbots/isaac-ros:sha-${REVISION}-arm64-jetpack"
CLI_NAMES="$(DRY_RUN=1 bash "$SCRIPT_DIR/build_robot_image.sh")"
CLI_TAG="${CLI_NAMES%%$'\n'*}"
if [[ "$CLI_TAG" != nvcr.io/nvidia/isaac/ros:*arm64-jetpack ]]; then
    echo "Could not determine the Isaac ROS CLI tag: $CLI_TAG" >&2
    exit 1
fi
docker pull "$REGISTRY_TAG"
docker tag "$REGISTRY_TAG" "$CLI_TAG"
echo "Pulled $REGISTRY_TAG; ready for isaac-ros activate."
