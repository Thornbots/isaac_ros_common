#!/usr/bin/env python3
"""Compare the dependency inputs available in existing published robot images."""
from pathlib import Path
import sys


PACKAGES = {
    'sllidar_ros2': 'sllidar_ros2',
    'ros2_dji_serial_bridge': 'dji_serial_bridge',
    'Realsense_ROI_Depth_Rectifier': 'roi_depth_query',
    'rf2o_laser_odometry': 'rf2o_laser_odometry',
    'sentry_localization': 'sentry_localization',
    'thornbots_pkg': 'thornbots_pkg',
    'realsense-yolov8-nitros-bridge': 'realsense_yolov8_nitros_bridge',
}


def tree(root):
    """Compare all runtime/build files; README and Markdown docs are not inputs."""
    return {str(p.relative_to(root)): ('link', p.readlink().as_posix()) if p.is_symlink()
            else ('file', p.read_bytes())
            for p in root.rglob('*')
            if (p.is_file() or p.is_symlink())
            and p.name.lower() != 'readme' and p.suffix.lower() not in {'.md', '.markdown'}}


def mismatches(source, docker, baked_source):
    expected = source / 'isaac_ros_common/docker'
    errors = []
    if not docker.is_dir() or tree(expected) != tree(docker):
        errors.append('isaac_ros_common/docker (non-document files, including Dockerfile)')
    for directory in PACKAGES:
        local = source / directory / 'package.xml'
        baked = baked_source / directory / 'package.xml'
        if not local.is_file() or not baked.is_file() or local.read_bytes() != baked.read_bytes():
            errors.append(f'{directory}/package.xml')
    return errors


def main():
    errors = mismatches(Path('/workspaces/isaac_ros-dev/src'),
                        Path('/opt/thornbots/docker'), Path('/workspaces/ros2_ws/src'))
    if errors:
        print('Robot image dependency mismatch; offline overlay build refused:', file=sys.stderr)
        for error in errors:
            print(f'  {error}', file=sys.stderr)
        print('Pull a compatible nightly/exact registry tag before building. '
              'If none exists, publish an image with these dependency inputs.', file=sys.stderr)
        return 1
    print('Robot image dependency contract matches checkout.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
