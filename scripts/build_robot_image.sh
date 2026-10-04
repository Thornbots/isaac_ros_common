#!/bin/bash
# build_robot_image.sh: build the robots' image (arm64-jetpack) on a robot, an
# arm64 host (the Mac's colima VM) or an x86 laptop under QEMU, then optionally
# ship it:
#   build_robot_image.sh                    # build; prints the tag
#   build_robot_image.sh ts-nano-sentry ... # build, then push and pull on each robot
#   SEED_FROM=blaises-mini build_robot_image.sh ...  # first copy missing base layers
#   DRY_RUN=1 build_robot_image.sh          # print the tag and base layers only
# Same tag `isaac-ros activate` computes on a robot from the same checkout, so
# activate there starts it without building.
# see isaac_ros_common/docker/README.md for design rationale
set -euo pipefail

HERE="$(dirname "$(realpath "$0")")"
export ISAAC_ROS_WS="$(realpath "$HERE/../../..")"
P="${ISAAC_ROS_CLI_PREFIX:-$HOME/.local/share/isaac-ros-cli}"
export ISAAC_ROS_CLI_ETC="$P/etc" PYTHONPATH="$P/lib"

# The CLI builds with `--builder default`; on the Mac the context is colima, so
# point the default context at it.
export DOCKER_HOST="${DOCKER_HOST:-$(docker context inspect -f '{{.Endpoints.docker.Host}}')}"
arch=$(docker info --format '{{.Architecture}}')
if [ "$arch" = x86_64 ]; then
    [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || {
        echo "x86_64 needs arm64 emulation: sudo pacman -S qemu-user-static qemu-user-static-binfmt" >&2
        exit 1; }
    export DOCKER_DEFAULT_PLATFORM=linux/arm64
elif [ "$arch" != aarch64 ]; then
    echo "docker runs on $arch; this builds on aarch64, or x86_64 under QEMU" >&2; exit 1
fi
[ -x "$P/venv/bin/python" ] || bash "$HERE/install_isaac_ros_cli.sh"
bash "$HERE/setup_workspace.sh" >/dev/null

# activate's own config merge, build args and layer order, with the platform
# pinned to Jetson instead of detected from this host. BUILD unset: print the
# image's tag, then each base layer's local tag.
cli() {
    "$P/venv/bin/python" - <<'EOF'
import os, sys
from isaac_ros_cli.config import load_config
from isaac_ros_cli.commands.activate.docker import _get_isaac_debian_build_args
from isaac_ros_common_config_utils import (
    get_build_order, get_isaac_ros_common_config_path, get_isaac_ros_common_config_values)
import build_image_layers as bil

cfg = load_config()
keys = cfg.docker.image.base_image_keys + cfg.docker.image.additional_image_keys
args = _get_isaac_debian_build_args(cfg)
path = get_isaac_ros_common_config_path()
order = str(get_isaac_ros_common_config_values(path)['image_key_order'][0]).split('.')
envs = get_build_order(order, keys)
out = os.fdopen(os.dup(1), 'w')
os.dup2(2, 1)  # build logs, docker's included, to the terminal; only names to stdout
names = [bil.get_image_name('nvcr.io/nvidia/isaac/ros', envs[:i], 'arm64-jetpack',
                            include_hash=True, build_args=args)
         for i in range(1, len(envs) + 1)]
if not os.environ.get('BUILD'):
    # Base layers are tagged <registry>/<name>:latest (the bake's BASE_IMAGE).
    print(names[-1], *(n.replace('ros:', 'ros/', 1) + ':latest' for n in names[:-1]),
          sep='\n', file=out)
    sys.exit()
bil.main(envs, target_image_name=names[-1], config_file=path, build_args=args,
         platform_='aarch64', build_local=True, isaac_ros_platform='arm64-jetpack',
         leaf_only=os.environ['BUILD'] == 'leaf')
EOF
}
names=$(cli)
TAG=$(head -1 <<<"$names")
BASES=$(tail -n +2 <<<"$names")
[ -z "${DRY_RUN:-}" ] || { echo "$names"; exit; }

have() { docker image inspect "$1" >/dev/null 2>&1; }
if [ -n "${SEED_FROM:-}" ]; then
    # Once per base-layer change: docker save on the host that has them (the Mac
    # mini), loaded here. Saves rebuilding librealsense under QEMU.
    for b in $BASES; do
        have "$b" && continue
        echo "copying $b from $SEED_FROM"
        ssh "$SEED_FROM" "PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH docker save $b" | docker load
    done
fi
# With every base layer here, build only Dockerfile.thornbots on them: the CLI's
# own skip asks the registry, which never has them.
mode=leaf
for b in $BASES; do have "$b" || mode=all; done
echo "building ($mode layers) $TAG"
BUILD=$mode cli
have "$TAG" || { echo "no $TAG: the build failed" >&2; exit 1; }  # the CLI can exit 0
echo "built $TAG ($(docker image inspect -f '{{len .RootFS.Layers}}' "$TAG") layers)"

[ $# -gt 0 ] || exit 0
# A registry on this host, pulled through an ssh -R tunnel: only layers the
# robot lacks cross, and docker trusts plain-http registries on localhost. 5055,
# as macOS AirPlay holds 5000.
docker start thornbots-registry >/dev/null 2>&1 ||
    docker run -d --name thornbots-registry --restart unless-stopped \
        -p 127.0.0.1:5055:5000 -v thornbots-registry:/var/lib/registry registry:2
R=localhost:5055/thornbots:${TAG##*_}
docker tag "$TAG" "$R"
docker push -q "$R"
for host in "$@"; do
    echo "pulling on $host"
    ssh -o ExitOnForwardFailure=yes -R 5055:localhost:5055 "$host" \
        "docker pull -q $R && docker tag $R $TAG && docker rmi -f $R >/dev/null"
done
