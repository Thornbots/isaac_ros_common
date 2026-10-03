#!/bin/bash
# build_robot_image.sh: build the robots' image (arm64-jetpack) on a robot, or on
# another arm64 host (the Mac's colima VM, a stopgap), then optionally ship it:
#   build_robot_image.sh                    # build; prints the tag
#   build_robot_image.sh ts-nano-sentry ... # build, then push and pull on each robot
#   DRY_RUN=1 build_robot_image.sh          # print the tag only
# Same tag `isaac-ros activate` computes on a robot from the same checkout, so
# activate there starts it without building. Needs docker on aarch64 (no QEMU).
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
[ "$arch" = aarch64 ] || { echo "docker runs on $arch; this builds arm64 natively only" >&2; exit 1; }
[ -x "$P/venv/bin/python" ] || bash "$HERE/install_isaac_ros_cli.sh"
bash "$HERE/setup_workspace.sh" >/dev/null

# activate's own config merge, build args and layer order, with the platform
# pinned to Jetson instead of detected from this host.
TAG=$("$P/venv/bin/python" - <<'EOF'
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
tag_out = os.fdopen(os.dup(1), 'w')
os.dup2(2, 1)  # build logs, docker's included, to the terminal; only the tag to $TAG
name = bil.get_image_name('nvcr.io/nvidia/isaac/ros', envs, 'arm64-jetpack',
                          include_hash=True, build_args=args)
if os.environ.get('DRY_RUN'):
    print(name, file=tag_out); sys.exit()
bil.main(envs, target_image_name=name, config_file=path, build_args=args,
         platform_='aarch64', build_local=True, isaac_ros_platform='arm64-jetpack')
print(name, file=tag_out)
EOF
)
[ -z "${DRY_RUN:-}" ] || { echo "$TAG"; exit; }
docker image inspect "$TAG" >/dev/null   # build_image_layers exits 0 on some failures
echo "built $TAG ($(docker image inspect -f '{{len .RootFS.Layers}}' "$TAG") layers)"

[ $# -gt 0 ] || exit 0
# A registry on the Mac, pulled through an ssh -R tunnel: only layers the robot
# lacks cross, and docker trusts plain-http registries on localhost. 5055, as
# macOS AirPlay holds 5000.
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
