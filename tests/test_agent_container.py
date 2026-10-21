"""Exercise real lifecycle functions with inert Docker, lock and VM boundaries."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/agent_container.sh'
SOURCE = SCRIPT.read_text().split('sub="${1:-}";')[0]
MOCKS = r'''
OS=Linux
DEXEC="$STATE/dexec"
lock() { HELD=1; }
unlock() { HELD=0; }
colima_up() { :; }
colima_stop_if_idle() { echo idle >> "$STATE/calls"; }
sleep() { :; }
docker() {
    echo "$*" >> "$STATE/calls"
    local name fmt token arg last="${!#}"
    case "$1" in
        inspect)
            name="$last"
            [ "$name" != isaac-agent-fixture ] || name="$(cat "$STATE/name" 2>/dev/null)"
            [ -n "$name" ] && [ -f "$STATE/$name" ] || return 1
            if [ "$MODE" = duplicate-signal ]; then kill -TERM $$; fi
            [ "${2:-}" = -f ] || return 0
            fmt="$3"
            case "$fmt" in
                *'.Id'*)
                    if [ "$MODE" = id-fail ] && [ ! -f "$STATE/id-failed" ]; then
                        touch "$STATE/id-failed"; return 1
                    fi
                    echo "$name" ;;
                *'thornbots.invocation'*) cat "$STATE/$name" ;;
                *'thornbots.agent'*) echo fixture ;;
                *'thornbots.domain'*) echo 100 ;;
                *'thornbots.partition'*) echo agent-fixture-100 ;;
                *'thornbots.src'*) echo "$WORKSPACE" ;;
                *) return 99 ;;
            esac ;;
        ps) return 0 ;;
        volume)
            case "$2" in
                inspect)
                    [ -f "$STATE/$last" ] || return 1
                    [ "${3:-}" != -f ] || cat "$STATE/$last" ;;
                create)
                    token=""
                    for arg in "$@"; do case "$arg" in thornbots.invocation=*) token="${arg#*=}" ;; esac; done
                    echo "$token" > "$STATE/$last"
                    if [ "$MODE" = volume-race ]; then echo other-invocation > "$STATE/$last"; fi
                    if [ "$MODE" = volume-fail ] && [ "$last" = isaac-agent-fixture-install ]; then return 1; fi
                    if [ "$MODE" = volume-signal ]; then kill -TERM $$; fi ;;
                rm) rm "$STATE/$last" ;;
                *) return 99 ;;
            esac ;;
        run)
            token=""
            for arg in "$@"; do case "$arg" in thornbots.invocation=*) token="${arg#*=}" ;; esac; done
            echo owned-id > "$STATE/name"
            echo "$token" > "$STATE/owned-id"
            [ "$MODE" != run-fail ] ;;
        exec)
            if [ "$MODE" = ready-fail ]; then return 1; fi
            if [ "$MODE" = ready-signal ]; then kill -TERM $$; fi
            if [ "$MODE" = chown-fail ] && [ "$2" = -u ]; then return 1; fi ;;
        rm)
            rm "$STATE/$last"
            if [ "$(cat "$STATE/name")" = "$last" ]; then rm "$STATE/name"; fi ;;
        *) echo "unexpected Docker boundary: $*" >&2; return 99 ;;
    esac
}
'''


class AgentContainerTest(unittest.TestCase):
    def exercise(self, mode, command='run', existing=False, orphan=False):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            workspace = state / 'workspace'
            (workspace / 'isaac_ros_common').mkdir(parents=True)
            (state / 'dexec').write_text(
                '#!/bin/bash\n'
                'echo dexec >> "$STATE/calls"\n'
                'if [ "$MODE" = replacement ]; then\n'
                '  echo replacement-id > "$STATE/name"\n'
                '  echo other-invocation > "$STATE/replacement-id"\n'
                'fi\n'
                'if [ "$MODE" = command-signal ]; then kill -TERM "$PPID"; fi\n'
                '[ "$MODE" != command-fail ] || exit 42\n')
            (state / 'dexec').chmod(0o755)
            if existing:
                (state / 'name').write_text('existing-id\n')
                (state / 'existing-id').write_text('old-invocation\n')
            if existing or orphan:
                (state / 'isaac-agent-fixture-build').write_text('old-invocation\n')
            invocation = f'cmd_{command} fixture -w {shlex.quote(str(workspace))} -i fake'
            if command == 'run':
                invocation += ' -- true'
            result = subprocess.run(
                ['/bin/bash', '-c', SOURCE + MOCKS + invocation],
                env=dict(os.environ, STATE=tmp, MODE=mode, WORKSPACE=str(workspace)),
                capture_output=True, text=True, timeout=10)
            files = {p.name: p.read_text() for p in state.iterdir() if p.is_file()}
            return result, files

    def test_duplicate_failure_and_signal_preserve_existing_resources(self):
        for mode in ['duplicate', 'duplicate-signal']:
            for command in ['run', 'up']:
                with self.subTest(mode=mode, command=command):
                    result, files = self.exercise(mode, command, existing=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(files['existing-id'], 'old-invocation\n')
                    self.assertEqual(files['isaac-agent-fixture-build'], 'old-invocation\n')
                    self.assertNotIn('rm -f', files['calls'])
                    self.assertNotIn('idle', files['calls'])

    def test_orphaned_volume_is_not_reused_or_deleted(self):
        result, files = self.exercise('normal', orphan=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(files['isaac-agent-fixture-build'], 'old-invocation\n')
        self.assertNotIn('volume create', files['calls'])

    def test_volume_created_by_a_racing_invocation_is_preserved(self):
        result, files = self.exercise('volume-race')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(files['isaac-agent-fixture-build'], 'other-invocation\n')
        self.assertNotIn('volume rm', files['calls'])

    def test_partial_startup_failures_and_signals_remove_only_owned_resources(self):
        for mode in ['volume-fail', 'volume-signal', 'run-fail', 'ready-fail',
                     'ready-signal', 'chown-fail', 'id-fail']:
            for command in ['run', 'up']:
                with self.subTest(mode=mode, command=command):
                    result, files = self.exercise(mode, command)
                    self.assertNotEqual(result.returncode, 0, result.stderr)
                    self.assertFalse(any(n.startswith('isaac-agent-') for n in files), files)
                    self.assertNotIn('owned-id', files)
                    self.assertNotIn('dexec\n', files['calls'])

    def test_normal_and_command_failure_cleanup_use_immutable_id(self):
        for mode, rc in [('normal', 0), ('command-fail', 42), ('command-signal', 143), ('replacement', 0)]:
            with self.subTest(mode=mode):
                result, files = self.exercise(mode)
                self.assertEqual(result.returncode, rc, result.stderr)
                self.assertIn('rm -f -v owned-id\n', files['calls'])
                self.assertNotIn('owned-id', files)
                self.assertFalse(any(n.startswith('isaac-agent-') for n in files), files)
                if mode == 'replacement':
                    self.assertEqual(files['replacement-id'], 'other-invocation\n')

    def test_successful_up_retains_resources_for_explicit_down(self):
        result, files = self.exercise('normal', command='up')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('owned-id', files)
        self.assertNotIn('rm -f', files['calls'])


if __name__ == '__main__':
    unittest.main()
