#!/usr/bin/env bash
# Invoked in a clean environment by build_robot_overlay.sh, with no network.
set -eo pipefail
cd /workspaces/isaac_ros-dev
source /opt/ros/jazzy/setup.bash
export MAKEFLAGS=-j2
packages=(sllidar_ros2 dji_serial_bridge roi_depth_query rf2o_laser_odometry
    sentry_localization thornbots_pkg realsense_yolov8_nitros_bridge)
paths=(src/sllidar_ros2 src/ros2_dji_serial_bridge src/Realsense_ROI_Depth_Rectifier
    src/rf2o_laser_odometry src/sentry_localization src/thornbots_pkg
    src/realsense-yolov8-nitros-bridge)
colcon build --parallel-workers 2 --symlink-install --base-paths "${paths[@]}" --packages-select "${packages[@]}" \
    --cmake-args -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF
source install/local_setup.bash
for package in "${packages[@]}"; do
    prefix="$(ros2 pkg prefix "$package")"
    [[ "$prefix" == "/workspaces/isaac_ros-dev/install/$package" ]] || {
        echo "Overlay prefix mismatch: $package resolved to $prefix" >&2; exit 1;
    }
done
