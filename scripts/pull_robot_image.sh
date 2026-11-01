#!/usr/bin/env bash
# Pull occasionally while online; pin only a compatible immutable image locally.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SRC="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
WS="$(dirname "$SRC")"
[[ "$#" -le 1 ]] || { echo 'usage: pull_robot_image.sh [TAG]' >&2; exit 2; }
TAG="${1:-nightly-arm64-jetpack}"
[[ "$TAG" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] || { echo 'Expected a registry tag, not an image URL.' >&2; exit 2; }
REF="ghcr.io/thornbots/isaac-ros:$TAG"
docker pull "$REF"
IMAGE="$(docker image inspect --format '{{.Id}}' "$REF")"
"$SCRIPT_DIR/check_robot_image.sh" "$IMAGE"
# Keep the prepared image tagged even when the remote nightly tag moves.
docker tag "$IMAGE" "thornbots-robot-base:${IMAGE#sha256:}"
TEMP="$(mktemp "$WS/.robot-image.XXXXXXXX")"
trap 'rm -f "$TEMP"' EXIT
printf '%s\n' "$IMAGE" > "$TEMP"
mv "$TEMP" "$WS/.robot-image"
echo "Pinned $REF as $IMAGE in $WS/.robot-image."
