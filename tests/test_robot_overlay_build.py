"""Run the real build body with inert ROS/colcon boundaries on the host."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/robot_overlay_build.sh'
PACKAGES = ['sllidar_ros2', 'dji_serial_bridge', 'roi_depth_query',
            'rf2o_laser_odometry', 'sentry_localization', 'thornbots_pkg',
            'realsense_yolov8_nitros_bridge']


class OverlayBuildTest(unittest.TestCase):
    def exercise(self, fail=False, bad_prefix=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root / 'install').mkdir()
            (root / 'install/local_setup.bash').write_text('echo overlay >> "$CALLS"\n')
            setup = root / 'setup.bash'
            setup.write_text('echo jazzy >> "$CALLS"\n')
            binaries = root / 'bin'
            binaries.mkdir()
            colcon = binaries / 'colcon'
            colcon.write_text('#!/bin/bash\n'
                              'echo "colcon MAKEFLAGS=$MAKEFLAGS $*" >> "$CALLS"\n'
                              'exit "${BUILD_RC:-0}"\n')
            ros2 = binaries / 'ros2'
            ros2.write_text('#!/bin/bash\n'
                            'echo "ros2 $*" >> "$CALLS"\n'
                            'if [[ "${BAD_PREFIX:-0}" == 1 ]]; then\n'
                            'echo /workspaces/ros2_ws/install/"$3"\n'
                            'else echo /workspaces/isaac_ros-dev/install/"$3"; fi\n')
            for binary in [colcon, ros2]:
                binary.chmod(0o755)
            body = SCRIPT.read_text().replace('cd /workspaces/isaac_ros-dev', f'cd "{root}"')
            body = body.replace('/opt/ros/jazzy/setup.bash', str(setup))
            calls = root / 'calls'
            result = subprocess.run(['bash', '-c', body], capture_output=True, text=True,
                                    env=dict(os.environ, PATH=f'{binaries}:{os.environ["PATH"]}',
                                             CALLS=str(calls), BUILD_RC='1' if fail else '0',
                                             BAD_PREFIX='1' if bad_prefix else '0'))
            return result, calls.read_text().splitlines()

    def test_all_seven_build_and_resolve_only_after_jazzy_and_local_setup(self):
        result, calls = self.exercise()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[0], 'jazzy')
        self.assertIn('--packages-select ' + ' '.join(PACKAGES), calls[1])
        self.assertIn('MAKEFLAGS=-j6 build --parallel-workers 3 --symlink-install', calls[1])
        self.assertIn('--symlink-install --base-paths src/sllidar_ros2', calls[1])
        self.assertEqual(calls[2], 'overlay')
        self.assertEqual(calls[3:], ['ros2 pkg prefix ' + package for package in PACKAGES])

    def test_colcon_failure_never_sources_overlay(self):
        result, calls = self.exercise(fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 2)

    def test_baked_prefix_is_rejected(self):
        result, _ = self.exercise(bad_prefix=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Overlay prefix mismatch', result.stderr)
