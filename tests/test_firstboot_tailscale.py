"""Regress firstboot authentication decisions without contacting a tailnet."""

import shutil
import subprocess
import sys
import unittest

import test_robot_firstboot


TAILSCALE = r'''
import json
import os
from pathlib import Path
import sys

path = Path(os.environ['FIRSTBOOT_TEST_STATE'])
state = json.loads(path.read_text())
args = sys.argv[1:]
state['calls'].append({'command': 'tailscale', 'args': args, 'marked': False})
if args == ['status', '--json']:
    samples = state['statuses']
    sample = samples.pop(0) if len(samples) > 1 else samples[0]
    path.write_text(json.dumps(state))
    if sample == 'invalid':
        print('not JSON')
        sys.exit(1)
    print(json.dumps({'BackendState': sample}))
    sys.exit(0 if sample == 'Running' else 1)
path.write_text(json.dumps(state))
if args[0] == 'up':
    if state.get('auth_fail'):
        print('suggested command: tailscale up ' + ' '.join(args), file=sys.stderr)
        sys.exit(1)
    sys.exit(0)
if args == ['ip', '-4']:
    print('100.64.0.1')
'''


class FirstbootTailscaleTest(unittest.TestCase):
    def setUp(self):
        self.fixture = test_robot_firstboot.RobotFirstbootTest()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        f = self.fixture
        with (f.state_dir / 'robot.env').open('a') as stream:
            stream.write('TS_AUTHKEY=tskey-client-test-secret\n')
        for command in ('python3', 'timeout'):
            (f.bin / command).symlink_to(sys.executable if command == 'python3'
                                         else shutil.which(command))
        (f.bin / 'tailscale').unlink()
        (f.bin / 'tailscale').write_text(f'#!{sys.executable}\n' + TAILSCALE)
        (f.bin / 'tailscale').chmod(0o755)

    def run_states(self, statuses, **values):
        self.fixture.configure(statuses=statuses, **values)
        return self.fixture.run_script()

    def up_calls(self):
        return [call['args'] for call in self.fixture.calls()
                if call['command'] == 'tailscale' and call['args'][0] == 'up']

    def assert_retryable(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.fixture.marker.exists())
        self.assertNotIn('setup_workspace', [call['command'] for call in self.fixture.calls()])
        self.assertNotIn('tskey-client-test-secret', result.stdout + result.stderr)

    def test_running_preserves_preferences_without_up(self):
        result = self.run_states(['Running'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.fixture.marker.exists())
        self.assertEqual(self.up_calls(), [])

    def test_authenticated_startup_waits_without_redeeming_key(self):
        result = self.run_states(['invalid', 'NoState', 'Starting', 'Running'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.up_calls(), [])
        status_calls = [call for call in self.fixture.calls()
                        if call['command'] == 'tailscale' and call['args'] == ['status', '--json']]
        self.assertEqual(len(status_calls), 4)

    def test_needslogin_authenticates_once_and_waits_for_running(self):
        result = self.run_states(['Starting', 'NeedsLogin', 'Starting', 'Running'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.up_calls(), [[
            'up', '--ssh', '--hostname', 'ts-test', '--advertise-tags=tag:jetsons',
            '--accept-dns=false', '--authkey',
            'tskey-client-test-secret?ephemeral=false&preauthorized=true',
        ]])

    def test_startup_timeout_never_redeems_key(self):
        result = self.run_states(['Starting'])
        self.assert_retryable(result)
        self.assertEqual(self.up_calls(), [])
        self.assertIn('not ready', result.stderr)
        self.assertEqual(sum(call['args'] == ['status', '--json']
                             for call in self.fixture.calls()), 30)

    def test_invalid_status_never_redeems_key(self):
        result = self.run_states(['invalid'])
        self.assert_retryable(result)
        self.assertEqual(self.up_calls(), [])

    def test_stopped_node_does_not_reauthenticate(self):
        result = self.run_states(['Stopped'])
        self.assert_retryable(result)
        self.assertEqual(self.up_calls(), [])

    def test_failed_auth_suppresses_secret_and_does_not_retry(self):
        self.fixture.configure(statuses=['NeedsLogin'], auth_fail=True)
        result = subprocess.run(
            [str(self.fixture.bin / 'bash'), '-x', str(self.fixture.firstboot)],
            env=self.fixture.env, text=True, capture_output=True, check=False, timeout=10)
        self.assert_retryable(result)
        self.assertEqual(len(self.up_calls()), 1)
        self.assertIn('authentication failed', result.stderr)

    def test_auth_success_without_running_does_not_redeem_again(self):
        result = self.run_states(['NeedsLogin'])
        self.assert_retryable(result)
        self.assertEqual(len(self.up_calls()), 1)

    def test_network_startup_failure_after_auth_remains_retryable(self):
        result = self.run_states(['NeedsLogin', 'Starting'])
        self.assert_retryable(result)
        self.assertEqual(len(self.up_calls()), 1)


if __name__ == '__main__':
    unittest.main()
