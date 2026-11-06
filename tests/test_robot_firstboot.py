"""Exercise firstboot/setup recovery with fixture paths and mocked host commands."""

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest


MOCK = r'''
import json
import os
from pathlib import Path
import signal
import sys

path = Path(os.environ['FIRSTBOOT_TEST_STATE'])
state = json.loads(path.read_text())
command = Path(sys.argv[0]).name
args = sys.argv[1:]
marker = Path(state['marker'])
state['calls'].append({'command': command, 'args': args, 'marked': marker.exists()})
path.write_text(json.dumps(state))
if state.get('fail') == [command, *args]:
    sys.exit(23)
if state.get('interrupt') == command:
    os.kill(os.getppid(), signal.SIGTERM)
    sys.exit(0)
if command == 'sudo':
    assert args[:3] == ['-u', 'robot-test', '-H']
    os.execvp(args[3], args[3:])
elif command == 'id':
    print('0')
elif command == 'getent':
    print('robot-test:x:1000:1000:Robot:' + state['home'] + ':/bin/bash')
elif command == 'tailscale' and args == ['ip', '-4']:
    print('100.64.0.1')
elif command == 'docker':
    print('jazzy-realsense-thornbots')
elif command == 'touch':
    assert args == ['--', str(marker)] or args == [str(marker.parent / 'image-done')]
    Path(args[-1]).touch()
'''


class RobotFirstbootTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.state_dir = self.root / 'firstboot'
        self.state_dir.mkdir()
        self.marker = self.state_dir / 'stage1-done'
        self.home = self.root / 'home'
        source = self.home / 'workspaces/isaac_ros-dev/src'
        (source / '.git').mkdir(parents=True)
        scripts = source / 'isaac_ros_common/scripts'
        scripts.mkdir(parents=True)
        startup = source / 'isaac-ros-startup'
        startup.mkdir()
        (self.root / 'etc/sudoers.d').mkdir(parents=True)
        (self.root / 'etc/nvpmodel.conf').write_text('< POWER_MODEL ID=7 NAME=MAXN_SUPER >\n')
        (self.state_dir / 'robot.env').write_text(
            'ROBOT_USER=robot-test\nROBOT_HOSTNAME=ts-test\nWS_REPO=unused\n')
        original = Path(__file__).resolve().parents[1] / 'scripts'
        self.firstboot = self.root / 'robot-firstboot.sh'
        self.firstboot.write_text((original / 'usb_installer/robot-firstboot.sh').read_text()
                                  .replace('/var/lib/robot-firstboot', str(self.state_dir)))
        self.setup = scripts / 'robot_setup.sh'
        self.setup.write_text((original / 'robot_setup.sh').read_text()
                              .replace('/etc/', str(self.root / 'etc') + '/'))
        for target, command in (
                (scripts / 'setup_workspace.sh', 'setup_workspace'),
                (scripts / 'jetson_setup.sh', 'jetson_setup'),
                (scripts / 'jetson_trim.sh', 'jetson_trim'),
                (startup / 'install.sh', 'startup_install')):
            target.write_text(f'#!/bin/bash\nexec {command} "$@"\n')
            target.chmod(0o755)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        mock = self.root / 'mock.py'
        mock.write_text(f'#!{sys.executable}\n' + MOCK)
        mock.chmod(0o755)
        # Mock chmod too: repeated root setup must rewrite its read-only sudoers file.
        for command in ('sudo', 'id', 'getent', 'curl', 'tailscale', 'git', 'apt-get',
                        'visudo', 'timedatectl', 'nvpmodel', 'systemctl', 'docker',
                        'isaac-ros', 'setup_workspace', 'jetson_setup', 'jetson_trim',
                        'startup_install', 'touch', 'sleep', 'chmod'):
            (self.bin / command).symlink_to(mock)
        # Only these safe utilities can fall through to the host implementation.
        for command in ('bash', 'dirname', 'readlink', 'cut', 'seq', 'sed',
                        'grep', 'env', 'mkdir'):
            (self.bin / command).symlink_to(shutil.which(command))
        self.state_path = self.root / 'state.json'
        self.state_path.write_text(json.dumps({
            'calls': [], 'marker': str(self.marker), 'home': str(self.home),
        }))
        self.env = dict(os.environ, PATH=str(self.bin),
                        FIRSTBOOT_TEST_STATE=str(self.state_path), SUDO_USER='robot-test')
        self.env.pop('ROBOT_SETUP_COMPLETE_FILE', None)
        self.env.pop('BASH_ENV', None)
        self.env.pop('ENV', None)

    def configure(self, **values):
        state = json.loads(self.state_path.read_text())
        state.update(values)
        self.state_path.write_text(json.dumps(state))

    def calls(self):
        return json.loads(self.state_path.read_text())['calls']

    def run_script(self, *, manual=False, marker=None):
        env = self.env.copy()
        if marker is not None:
            env['ROBOT_SETUP_COMPLETE_FILE'] = str(marker)
        return subprocess.run([str(self.bin / 'bash'), str(self.setup if manual
                                                         else self.firstboot)],
                              env=env, text=True, capture_output=True, check=False,
                              timeout=10)

    def assert_no_image_or_reboot(self):
        commands = [call['command'] for call in self.calls()]
        for command in ('isaac-ros', 'docker', 'nvpmodel', 'systemctl'):
            self.assertNotIn(command, commands)
        self.assertFalse((self.state_dir / 'image-done').exists())

    def test_host_setup_failures_resume_setup_without_building_image(self):
        for failure in (['jetson_setup'], ['jetson_trim'],
                        ['startup_install', '--ws', str(self.home / 'workspaces/isaac_ros-dev')],
                        ['tailscale', 'set', '--ssh']):
            with self.subTest(failure=failure):
                self.marker.unlink(missing_ok=True)
                self.configure(calls=[], fail=failure)
                result = self.run_script()
                self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
                self.assertFalse(self.marker.exists())
                self.assert_no_image_or_reboot()
                self.configure(fail=None)
                result = self.run_script()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(self.marker.exists())
                commands = [call['command'] for call in self.calls()]
                self.assertEqual(commands.count('setup_workspace'), 2)
                self.assertEqual(commands.count('jetson_setup'), 2)
                self.assertNotIn('isaac-ros', commands)
                self.assertNotIn('docker', commands)

    def test_interrupted_host_setup_is_resumed_on_next_firstboot(self):
        self.configure(interrupt='jetson_trim')
        result = self.run_script()
        self.assertEqual(result.returncode, 128 + signal.SIGTERM, result.stderr)
        self.assertFalse(self.marker.exists())
        self.assert_no_image_or_reboot()
        self.configure(interrupt=None)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.marker.exists())
        commands = [call['command'] for call in self.calls()]
        self.assertEqual(commands.count('jetson_setup'), 2)
        self.assertEqual(commands.count('jetson_trim'), 2)
        self.assertNotIn('isaac-ros', commands)

    def test_marker_precedes_power_mode_reboot_and_next_boot_builds_image(self):
        self.configure(interrupt='nvpmodel')
        result = self.run_script()
        self.assertEqual(result.returncode, 128 + signal.SIGTERM, result.stderr)
        self.assertTrue(self.marker.exists())
        calls = self.calls()
        power = next(call for call in calls if call['command'] == 'nvpmodel')
        self.assertEqual(power['args'], ['-m', '7', '--force'])
        self.assertTrue(power['marked'])
        self.assertFalse(any(call['marked'] for call in calls
                             if call['command'] in ('jetson_setup', 'jetson_trim',
                                                    'startup_install', 'tailscale')))
        self.assertNotIn('systemctl', [call['command'] for call in calls])
        self.configure(calls=[], interrupt=None)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        self.assertIn(['activate', '--build-local', '--build-only'],
                      [call['args'] for call in calls if call['command'] == 'isaac-ros'])
        self.assertTrue((self.state_dir / 'image-done').exists())
        self.assertNotIn('jetson_setup', [call['command'] for call in calls])
        self.assertEqual([call['args'] for call in calls if call['command'] == 'systemctl'],
                         [['disable', 'robot-firstboot.service'], ['start', 'thornbots.service']])

    def test_manual_setup_without_marker_keeps_reboot_behavior(self):
        for marker in (None, ''):
            with self.subTest(marker=marker):
                self.configure(calls=[])
                result = self.run_script(manual=True, marker=marker)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(self.marker.exists())
                calls = self.calls()
                self.assertNotIn('touch', [call['command'] for call in calls])
                self.assertIn(['reboot'], [call['args'] for call in calls
                                          if call['command'] == 'systemctl'])

    def test_marker_write_failure_prevents_power_mode_change_and_reboot(self):
        self.configure(fail=['touch', '--', str(self.marker)])
        result = self.run_script()
        self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
        self.assertFalse(self.marker.exists())
        self.assert_no_image_or_reboot()
        self.assertIn('startup_install', [call['command'] for call in self.calls()])
        self.configure(fail=None)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.marker.exists())
        self.assertNotIn('isaac-ros', [call['command'] for call in self.calls()])


if __name__ == '__main__':
    unittest.main()
