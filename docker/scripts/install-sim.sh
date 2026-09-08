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

cd "${WS}"
colcon build ${COLCON_OPTS} --packages-select sim
