"""Container-local launch selection and pidfd signalling; see README safe stopping."""

import os
from pathlib import Path
import signal
import sys

PROC = Path('/proc')


def identity(pid):
    """A mount namespace plus exact cgroup membership proves container scope."""
    path = PROC / str(pid)
    return (os.readlink(path / 'ns/mnt'), (path / 'cgroup').read_bytes())


def process(pid):
    path = PROC / str(pid)
    # comm can contain spaces and parentheses; fields after its final ')' are fixed.
    fields = (path / 'stat').read_text().rsplit(')', 1)[1].split()
    argv = (path / 'cmdline').read_bytes().split(b'\0')
    return {'pid': pid, 'ppid': int(fields[1]), 'start': fields[19],
            'argv': [os.fsdecode(arg) for arg in argv if arg]}


def ros_root(info):
    argv = info['argv']
    # The ros2 console script is normally invoked through its Python shebang.
    index = 1 if argv and Path(argv[0]).name.startswith('python') else 0
    return (len(argv) > index + 1 and Path(argv[index]).name == 'ros2'
            and argv[index + 1] in ('launch', 'run'))


def owned(pid, scope):
    return pid > 1 and identity(pid) == scope


def main(args):
    scope = identity('self')
    processes = {}
    for path in PROC.iterdir():
        if not path.name.isdigit():
            continue
        pid = int(path.name)
        try:
            if owned(pid, scope):
                info = process(pid)
                if info['argv']:
                    processes[pid] = info
        except (OSError, ValueError):
            continue
    roots = {pid: info for pid, info in processes.items() if ros_root(info)}
    if args == ['-l']:
        print('PID COMMAND (container-owned ROS roots only)')
        for pid, info in sorted(roots.items()):
            print(pid, ' '.join(info['argv']))
        return
    if args[0] == '--match':
        selected = [pid for pid, info in roots.items()
                    if args[1] in ' '.join(info['argv'])]
    else:
        pid = int(args[0])
        if pid not in roots:
            raise RuntimeError(f'refusing PID {pid}: outside target container, '
                               'PID 1, gone, or not a ROS launch/run root')
        selected = [pid]
    if not selected:
        raise RuntimeError('refusing match: no container-owned ROS launch/run roots')
    targets = set(selected)
    while True:
        children = {pid for pid, info in processes.items() if info['ppid'] in targets}
        expanded = targets | children
        if expanded == targets:
            break
        targets = expanded
    # Pin every recipient before signalling. Never signal a numeric PID or group:
    # either can be reused or include foreign processes in a shared PID namespace.
    handles = []
    try:
        for pid in sorted(targets):
            try:
                fd = os.pidfd_open(pid)
            except ProcessLookupError:
                continue
            handles.append((pid, fd))
            if not owned(pid, scope) or process(pid)['start'] != processes[pid]['start']:
                raise RuntimeError(f'refusing changed process identity for PID {pid}')
        for pid, fd in handles:
            try:
                signal.pidfd_send_signal(fd, signal.SIGINT)
                print(f'Sent SIGINT to container-owned PID {pid}')
            except ProcessLookupError:
                pass
    finally:
        for _, fd in handles:
            os.close(fd)


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except (OSError, RuntimeError, ValueError, AttributeError) as error:
        print(f'kill_launch.sh: {error}', file=sys.stderr)
        sys.exit(1)
