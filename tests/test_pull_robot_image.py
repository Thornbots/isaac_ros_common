"""Check exact-image guards with local Git repositories and a stub Docker CLI."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'pull_robot_image.sh'
CLI_TAG = 'nvcr.io/nvidia/isaac/ros:fixture-arm64-jetpack'


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


if __name__ == '__main__':
    unittest.main()
