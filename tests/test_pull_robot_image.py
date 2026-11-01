"""Exercise robot image pinning and offline overlay orchestration."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'pull_robot_image.sh'
CLI_TAG = 'nvcr.io/nvidia/isaac/ros:fixture-arm64-jetpack'
BUILD_SCRIPT = SCRIPT.with_name('build_robot_image.sh')


class PullRobotImageTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.base = Path(self.directory.name)
        self.base = self.base.resolve()
        self.workspace = self.base / 'workspace'
        self.scripts = self.workspace / 'src/isaac_ros_common/scripts'
        self.scripts.mkdir(parents=True)
        for name in ['pull_robot_image.sh', 'check_robot_image.sh', 'build_robot_overlay.sh']:
            shutil.copy2(SCRIPT.with_name(name), self.scripts / name)
        helper = self.scripts / 'agent_container.sh'
        helper.write_text('#!/bin/bash\n'
                          'echo "$*" >> "$DOCKER_LOG"\n'
                          'case "$2" in\n'
                          'robot-check-*) exit "${CHECK_RC:-0}" ;;\n'
                          'robot-overlay-*) exit "${BUILD_RC:-0}" ;;\n'
                          'esac\n')
        helper.chmod(0o755)
        self.docker_log = self.base / 'docker.log'
        binaries = self.base / 'bin'
        binaries.mkdir()
        docker = binaries / 'docker'
        docker.write_text('#!/bin/bash\n'
                          'echo "$*" >> "$DOCKER_LOG"\n'
                          'if [[ "$*" == *thornbots-runtime* ]]; then\n'
                          '  if [[ "$*" == *State.Running* ]]; then echo "${RUNTIME_RUNNING:-false}";\n'
                          '  else echo "$RUNTIME_MOUNT"; fi; exit 0; fi\n'
                          'if [[ "$1" == pull ]]; then exit "${PULL_RC:-0}"; fi\n'
                          'if [[ "$*" == *--format* ]]; then echo "$IMAGE_ID"; fi\n')
        docker.chmod(0o755)
        self.image = 'sha256:' + 'a' * 64
        self.env = dict(os.environ, PATH=f'{binaries}:{os.environ["PATH"]}',
                        DOCKER_LOG=str(self.docker_log), IMAGE_ID=self.image)

    def run_script(self, name, *args):
        return subprocess.run(['bash', str(self.scripts / name), *args],
                              env=self.env, text=True, capture_output=True, timeout=10)

    def test_default_and_exact_tag_pin_immutable_id(self):
        for args, tag in [((), 'nightly-arm64-jetpack'),
                          (('sha-example-arm64-jetpack',), 'sha-example-arm64-jetpack')]:
            result = self.run_script('pull_robot_image.sh', *args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((self.workspace / '.robot-image').read_text(), self.image + '\n')
            self.assertIn('pull ghcr.io/thornbots/isaac-ros:' + tag,
                          self.docker_log.read_text())
            self.assertIn('-n -z -- python3', self.docker_log.read_text())

    def test_pull_or_contract_failure_preserves_pin(self):
        pin = self.workspace / '.robot-image'
        for failure in ['PULL_RC', 'CHECK_RC']:
            pin.write_text('previous\n')
            self.env[failure] = '1'
            result = self.run_script('pull_robot_image.sh')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(pin.read_text(), 'previous\n')
            self.env.pop(failure)

    def test_failed_rebuild_invalidates_marker_even_on_contract_failure(self):
        (self.workspace / '.robot-image').write_text(self.image + '\n')
        marker = self.workspace / '.robot-overlay-image'
        for failure in ['CHECK_RC', 'BUILD_RC']:
            marker.write_text(self.image + '\n')
            self.env[failure] = '1'
            result = self.run_script('build_robot_overlay.sh')
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(marker.exists())
            self.assertFalse((self.workspace / '.robot-overlay.lock').exists())
            self.env.pop(failure)

    def test_offline_check_and_build_use_pin_and_persistent_canonical_mount(self):
        (self.workspace / '.robot-image').write_text(self.image + '\n')
        marker = self.workspace / '.robot-overlay-image'
        marker.write_text('old\n')
        result = self.run_script('build_robot_overlay.sh', '--check')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(marker.read_text(), 'old\n')
        self.assertNotIn('robot-overlay-', self.docker_log.read_text())
        result = self.run_script('build_robot_overlay.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(marker.read_text(), self.image + '\n')
        calls = self.docker_log.read_text()
        self.assertIn(f'-p {self.workspace} -i {self.image} -n -z', calls)
        self.assertNotIn('pull ', calls)

    def test_active_runtime_sharing_artifacts_refuses_build(self):
        (self.workspace / '.robot-image').write_text(self.image + '\n')
        marker = self.workspace / '.robot-overlay-image'
        marker.write_text(self.image + '\n')
        self.env.update(RUNTIME_RUNNING='true', RUNTIME_MOUNT=str(self.workspace))
        result = self.run_script('build_robot_overlay.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Stop thornbots', result.stderr)
        self.assertNotIn('run robot-overlay-', self.docker_log.read_text())
        self.assertEqual(marker.read_text(), self.image + '\n')

    def test_invalid_pin_cannot_start_container(self):
        (self.workspace / '.robot-image').write_text('mutable-tag\n')
        result = self.run_script('build_robot_overlay.sh', '--check')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.docker_log.exists())


class BuildRobotImageTest(unittest.TestCase):
    def test_first_use_dry_run_keeps_installer_diagnostics_off_stdout(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            scripts = base / 'ws/src/isaac_ros_common/scripts'
            scripts.mkdir(parents=True)
            shutil.copyfile(BUILD_SCRIPT, scripts / BUILD_SCRIPT.name)
            (scripts / 'setup_workspace.sh').write_text('#!/usr/bin/env bash\nexit 0\n')
            (scripts / 'install_isaac_ros_cli.sh').write_text(
                '#!/usr/bin/env bash\nset -euo pipefail\n'
                'mkdir -p "$ISAAC_ROS_CLI_PREFIX/venv/bin"\n'
                'cp "$FAKE_CLI_PYTHON" "$ISAAC_ROS_CLI_PREFIX/venv/bin/python"\n'
                'chmod +x "$ISAAC_ROS_CLI_PREFIX/venv/bin/python"\n'
                'echo "installed: fixture CLI"\n')
            prefix_python = base / 'fake-python'
            base_tag = 'nvcr.io/nvidia/isaac/ros/fixture-base:latest'
            prefix_python.write_text(
                '#!/usr/bin/env bash\n'
                f'printf "%s\\n" "{CLI_TAG}" "{base_tag}"\n')
            binaries = base / 'bin'
            binaries.mkdir()
            docker = binaries / 'docker'
            docker.write_text(
                '#!/usr/bin/env bash\n'
                'printf "%s\\n" "$*" >> "$DOCKER_LOG"\n'
                'case "$1 $2" in\n'
                '  "context inspect") echo unix:///fixture/docker.sock ;;\n'
                '  "info --format") echo aarch64 ;;\n'
                '  *) echo "Unexpected Docker operation: $*" >&2; exit 99 ;;\n'
                'esac\n')
            docker.chmod(0o755)
            docker_log = base / 'docker.log'
            prefix = base / 'new-cli-prefix'
            env = dict(os.environ, DRY_RUN='1', ISAAC_ROS_CLI_PREFIX=str(prefix),
                       FAKE_CLI_PYTHON=str(prefix_python), DOCKER_HOST='',
                       DOCKER_LOG=str(docker_log), PATH=f'{binaries}:{os.environ["PATH"]}')
            self.assertFalse(prefix.exists())
            result = subprocess.run(['bash', str(scripts / BUILD_SCRIPT.name)],
                                    env=env, text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), [CLI_TAG, base_tag])
            self.assertIn('installed: fixture CLI', result.stderr)
            self.assertEqual(docker_log.read_text().splitlines(), [
                'context inspect -f {{.Endpoints.docker.Host}}',
                'info --format {{.Architecture}}'])


if __name__ == '__main__':
    unittest.main()
