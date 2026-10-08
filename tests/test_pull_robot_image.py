"""Check exact-image guards with local Git repositories and a stub Docker CLI."""
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
        self.workspace = self.base / 'workspace'
        self.workspace.mkdir()
        self.env = dict(os.environ, GIT_AUTHOR_NAME='Test', GIT_AUTHOR_EMAIL='test@example.org',
                        GIT_COMMITTER_NAME='Test', GIT_COMMITTER_EMAIL='test@example.org',
                        GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull)
        self.git(self.workspace, 'init', '-q')
        for package in ['isaac_ros_common', 'mandatory', 'sim', 'firmware/MCBV3']:
            source = self.base / package.replace('/', '-')
            source.mkdir()
            self.git(source, 'init', '-q')
            (source / 'tracked.txt').write_text('committed\n')
            if package == 'isaac_ros_common':
                scripts = source / 'scripts'
                scripts.mkdir()
                shutil.copyfile(SCRIPT, scripts / SCRIPT.name)
                (scripts / 'build_robot_image.sh').write_text(
                    '#!/usr/bin/env bash\n'
                    '[[ "${DRY_RUN:-}" == 1 ]] || exit 9\n'
                    f'printf "%s\\n" "{CLI_TAG}"\n')
            self.git(source, 'add', '.')
            self.git(source, 'commit', '-qm', 'fixture')
            self.git(self.workspace, '-c', 'protocol.file.allow=always',
                     'submodule', 'add', '-q', str(source), package)
        self.git(self.workspace, 'commit', '-qam', 'workspace fixture')
        self.revision = self.git(self.workspace, 'rev-parse', 'HEAD').strip()
        self.docker_log = self.base / 'docker.log'
        binaries = self.base / 'bin'
        binaries.mkdir()
        docker = binaries / 'docker'
        docker.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$DOCKER_LOG"\n')
        docker.chmod(0o755)
        self.env.update(PATH=f'{binaries}:{self.env["PATH"]}', DOCKER_LOG=str(self.docker_log))

    def git(self, directory, *args):
        return subprocess.run(['git', '-C', str(directory), *args], env=self.env,
                              check=True, text=True, capture_output=True).stdout

    def pull(self):
        return subprocess.run(
            ['bash', str(self.workspace / 'isaac_ros_common/scripts/pull_robot_image.sh')],
            env=self.env, text=True, capture_output=True, timeout=10)

    def assert_rejected(self):
        result = self.pull()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.docker_log.exists(), result.stdout)

    def test_clean_checkout_pulls_and_retags_exact_revision(self):
        result = self.pull()
        self.assertEqual(result.returncode, 0, result.stderr)
        tag = f'ghcr.io/thornbots/isaac-ros:sha-{self.revision}-arm64-jetpack'
        self.assertEqual(self.docker_log.read_text().splitlines(),
                         [f'pull {tag}', f'tag {tag} {CLI_TAG}'])

    def test_dirty_mandatory_package_is_rejected_before_docker(self):
        (self.workspace / 'mandatory/tracked.txt').write_text('modified\n')
        self.assert_rejected()

    def test_changed_mandatory_gitlink_is_rejected_before_docker(self):
        package = self.workspace / 'mandatory'
        (package / 'tracked.txt').write_text('modified\n')
        self.git(package, 'commit', '-qam', 'new revision')
        self.assert_rejected()

    def test_uninitialized_mandatory_package_is_rejected_before_docker(self):
        self.git(self.workspace, 'submodule', 'deinit', '-f', 'mandatory')
        self.assert_rejected()

    def test_staged_workspace_change_is_rejected_before_docker(self):
        (self.workspace / 'image-setting.txt').write_text('new image setting\n')
        self.git(self.workspace, 'add', 'image-setting.txt')
        self.assert_rejected()

    def test_optional_uninitialized_packages_allow_pull(self):
        self.git(self.workspace, 'submodule', 'deinit', '-f', 'sim', 'firmware/MCBV3')
        result = self.pull()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.docker_log.exists())

    def test_optional_dirty_packages_allow_pull(self):
        for package in ['sim', 'firmware/MCBV3']:
            (self.workspace / package / 'tracked.txt').write_text('modified\n')
        result = self.pull()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.docker_log.exists())


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
