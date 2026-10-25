"""Fail closed when a selected process changes before pidfd signalling."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

SPEC = importlib.util.spec_from_file_location(
    'kill_launch', Path(__file__).resolve().parents[1] / 'scripts/kill_launch.py')
HELPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPER)


class SignalSafetyTest(unittest.TestCase):
    def test_changed_scope_or_start_never_signals(self):
        original = {'pid': 42, 'ppid': 1, 'start': '100',
                    'argv': ['/usr/bin/python3', '/opt/ros/jazzy/bin/ros2',
                             'launch', 'fixture.launch.py']}
        for changed_scope in (False, True):
            with self.subTest(changed_scope=changed_scope):
                after = dict(original, start='100' if changed_scope else '200')
                proc = Mock()
                proc.iterdir.return_value = [Path('/proc/42')]
                with (patch.object(HELPER, 'PROC', proc),
                      patch.object(HELPER, 'identity', return_value=('mnt', b'cgroup')),
                      patch.object(HELPER, 'owned', side_effect=[True, not changed_scope]),
                      patch.object(HELPER, 'process', side_effect=[original, after]),
                      patch.object(HELPER.os, 'pidfd_open', return_value=7, create=True),
                      patch.object(HELPER.os, 'close') as close,
                      patch.object(HELPER.signal, 'pidfd_send_signal', create=True) as send):
                    with self.assertRaisesRegex(RuntimeError, 'changed process identity'):
                        HELPER.main(['42'])
                    send.assert_not_called()
                    close.assert_called_once_with(7)

    def test_wrapper_and_non_ros_commands_are_not_roots(self):
        for argv in (['bash', '-c', 'ros2 launch fixture.launch.py'],
                     ['sleep', '600'], ['ros2', 'topic', 'list'], []):
            with self.subTest(argv=argv):
                self.assertFalse(HELPER.ros_root({'argv': argv}))
        self.assertTrue(HELPER.ros_root({'argv': ['ros2', 'run', 'pkg', 'node']}))


if __name__ == '__main__':
    unittest.main()
