#!/bin/bash
# install-sim.sh
#
# Installs `sim`'s dependencies -- gz-sim via ros_gz from apt, and SAPIEN
# (sim_engine:=sapien) from pip -- and builds the package.
# Dockerfile.thornbots leaves all of it out on purpose: real hardware never
# launches a sim.
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

# sapien_sim.py's engine and its Embree lidar. --no-deps is required, not
# tidiness: SAPIEN's dependencies include opencv-python, which would shadow
# the system cv2 the CV stack uses. SAPIEN imports fine without it, and the
# node creates no renderer, so no GPU or Vulkan is needed. transforms3d is
# not optional: `import sapien` pulls in its viewer module, which imports it.
pip install --no-deps sapien trimesh embreex transforms3d

# Build as the workspace owner, not root: build/ and install/ are bind-mounted
# from the host, and root-owned files there break the next non-root
# `colcon build`. --symlink-install is explicit because sudo's env_reset
# drops the image's COLCON_OPTS.
OWNER_UID=$(stat -c %u "${WS}")
sudo -u "#${OWNER_UID}" bash -c "source '${ROS_SETUP:-/opt/ros/humble/setup.bash}' \
    && cd '${WS}' && colcon build --symlink-install ${COLCON_OPTS} --packages-select sim"
