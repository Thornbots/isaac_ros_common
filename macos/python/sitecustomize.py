"""
Restore DYLD_LIBRARY_PATH in Python ROS nodes on macOS.

SIP strips DYLD_* from any process started through /usr/bin/env, the
shebang of every installed ROS Python node, and dyld reads it only at exec,
so typesupport can't dlopen a workspace's message libraries. Rebuild it
from AMENT_PREFIX_PATH, which survives, and re-exec this interpreter once.
"""
import os
import sys

if sys.platform == 'darwin' and not os.environ.get('DYLD_LIBRARY_PATH'):
    _libs = [os.path.join(p, 'lib') for p in os.environ.get('AMENT_PREFIX_PATH', '').split(':')
             if p and os.path.isdir(os.path.join(p, 'lib'))]
    if _libs:
        os.environ['DYLD_LIBRARY_PATH'] = ':'.join(_libs)
        os.execv(sys.executable, sys.orig_argv)
