#!/bin/bash
# install-sim.sh
#
# Installs `sim`'s dependencies (gz-sim via ros_gz, ...) and builds the
# package. Dockerfile.thornbots leaves both out on purpose: real hardware
# never launches gz-sim.
#
# Run once per container (as root / via sudo) after attaching, before using
# `ros2 launch sim sim.launch.py`:
#   sudo isaac_ros_common/docker/scripts/install-sim.sh
set -e

WS=/workspaces/isaac_ros-dev
source "${ROS_SETUP:-/opt/ros/humble/setup.bash}"

# Deps come from the manifests, same as Dockerfile.thornbots LAYER 4 --
# --ignore-src covers our own packages, and realsense2_camera is skipped
# because Dockerfile.realsense builds it from source (see docker/README.md).
apt-get update
rosdep install -y --from-paths "${WS}/src" --ignore-src --rosdistro humble \
    --skip-keys "realsense2_camera realsense2_camera_msgs"
rm -rf /var/lib/apt/lists/*

# Build as the workspace owner, not root: build/ and install/ are bind-mounted
# from the host, and root-owned files there break the next non-root
# `colcon build`. --symlink-install is explicit because sudo's env_reset
# drops the image's COLCON_OPTS.
OWNER_UID=$(stat -c %u "${WS}")
sudo -u "#${OWNER_UID}" bash -c "source '${ROS_SETUP:-/opt/ros/humble/setup.bash}' \
    && cd '${WS}' && colcon build --symlink-install ${COLCON_OPTS} --packages-select sim"
