"""A real ROS launch with a child that records clean SIGINT shutdown."""
from launch import LaunchDescription
from launch.actions import ExecuteProcess


def generate_launch_description():
    code = (
        'import pathlib,signal,time; '
        'signal.signal(signal.SIGINT, lambda *_: '
        '(pathlib.Path("/tmp/kill-launch-stopped").touch(), exit(0))); '
        'pathlib.Path("/tmp/kill-launch-ready").touch(); '
        'time.sleep(600)'
    )
    return LaunchDescription([ExecuteProcess(cmd=['python3', '-c', code])])
