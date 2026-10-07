#!/usr/bin/env bash
# Pull the image for this exact workspace; retag it for isaac-ros-cli.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"
REVISION="$(git -C "$WORKSPACE_SRC" rev-parse HEAD)"
# The image excludes sim and firmware; every other package must match its gitlink.
while read -r _ package; do
    case "$package" in sim|firmware|firmware/*) continue ;; esac
    status="$(git -C "$WORKSPACE_SRC" submodule status --recursive -- "$package")"
    if [[ -z "$status" ]] || [[ "$status" == [-+U]* ]] ||
       [[ "$status" == *$'\n-'* || "$status" == *$'\n+'* || "$status" == *$'\nU'* ]]; then
        echo "Image package $package is uninitialized or differs from its recorded gitlink." >&2
        exit 1
    fi
    if ! git -C "$WORKSPACE_SRC/$package" diff --quiet HEAD; then
        echo "Image package $package has uncommitted tracked changes." >&2
        exit 1
    fi
done < <(git -C "$WORKSPACE_SRC" config --file .gitmodules --get-regexp '^submodule\..*\.path$')
if ! git -C "$WORKSPACE_SRC" diff --quiet HEAD -- . ':!sim' ':!firmware'; then
    echo 'Workspace has uncommitted image changes; commit them before pulling an exact image.' >&2
    exit 1
fi
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
