#!/bin/bash
# install-sim.sh
#
# Installs `sim`'s dependencies (gz-sim Harmonic via ros_gz from its
# package.xml, and trimesh from pip for tools/simplify_urdf.py) and builds
# the package. Dockerfile.thornbots leaves all of it out on purpose: real
# hardware never launches a sim.
#
# Run once per container (as root / via sudo) after attaching, before using
# `ros2 launch sim sim.launch.py`:
#   sudo isaac_ros_common/docker/scripts/install-sim.sh
set -e

WS=/workspaces/isaac_ros-dev
ROS_SETUP="${ROS_SETUP:-/opt/ros/jazzy/setup.bash}"
source "${ROS_SETUP}"

# Deps come from the manifests, same as Dockerfile.thornbots' rosdep layer.
# --ignore-src covers our own packages, and realsense2_camera is skipped
# because the CLI's Dockerfile.realsense builds it from source.
# isaac_ros_common is left out: its upstream packages are unbuilt, and 4.6's
# isaac_ros_test pulls ~3 GB of CUDA torch through python3-torch-pip-shim.
# Without Isaac ROS (Dockerfile.mac) the YOLO bridge's isaac_ros_* keys can't
# resolve either, so it is left out there too.
apt-get update
SKIP_DIRS=(isaac_ros_common)
[ -d /opt/ros/jazzy/share/isaac_ros_nitros_image_type ] \
    || SKIP_DIRS+=(realsense-yolov8-nitros-bridge)
PKG_DIRS=()
for d in "${WS}"/src/*/; do
    [[ " ${SKIP_DIRS[*]} " == *" $(basename "$d") "* ]] || PKG_DIRS+=("$d")
done
rosdep install -y --from-paths "${PKG_DIRS[@]}" --ignore-src --rosdistro jazzy \
    --skip-keys "realsense2_camera realsense2_camera_msgs"
rm -rf /var/lib/apt/lists/*

# Noble has no python3-trimesh and rosdep only knows it as a pip key, so pip
# it here. PEP 668 needs --break-system-packages; --no-deps keeps pip off the
# apt numpy the ROS stack uses.
pip install --break-system-packages --no-deps trimesh

# Build as the workspace owner, not root: build/ and install/ are bind-mounted
# from the host, and root-owned files there break the next non-root
# `colcon build`. --symlink-install is explicit because sudo's env_reset
# drops the image's COLCON_OPTS. --packages-up-to, since a fresh workspace has
# not built sim's dependency dji_serial_bridge yet.
OWNER_UID=$(stat -c %u "${WS}")
sudo -u "#${OWNER_UID}" bash -c "source '${ROS_SETUP}' \
    && cd '${WS}' && colcon build --symlink-install ${COLCON_OPTS} --packages-up-to sim"
