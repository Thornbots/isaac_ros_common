#!/bin/bash
# install-sim.sh
#
# Installs the gz-sim (ros_gz) deps and builds the `sim` package
# (isaac_ros-dev/src/sim, bind-mounted -- not cloned, no git step needed)
# for containers built from Dockerfile.thornbots, which does not install
# these by default since real hardware never launches gz-sim.
#
# Run once per container (as root / via sudo) after attaching, before using
# `ros2 launch sim sim.launch.py`:
#   sudo isaac_ros_common/docker/scripts/install-sim.sh
set -e

apt-get update
apt-get install -y --no-install-recommends ros-humble-ros-gz
rm -rf /var/lib/apt/lists/*

source "${ROS_SETUP:-/opt/ros/humble/setup.bash}"
cd /workspaces/isaac_ros-dev
colcon build ${COLCON_OPTS} --packages-select sim
