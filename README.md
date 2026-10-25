# Isaac ROS Common

Essential utilities, packages, scripts, and testing infrastructure for Isaac ROS packages.

## Thornbots fork

This fork adds the Thornbots image and host setup on top of NVIDIA
`release-4.6`; everything below this section is upstream.

- Clone the workspace: [submodules](../README.md#working-with-submodules).
- Isaac ROS image: [`Dockerfile.thornbots`](docker/README.md#dockerfilethornbots);
  [build it locally](docker/README.md#building) or, on robots,
  [pull it from GHCR](docker/README.md#pulling-from-github-container-registry).
- Apple Silicon: [`Dockerfile.mac` container](docker/README.md#dockerfilemac)
  or [native RoboStack](macos/README.md).
- Windows with an NVIDIA GPU: [Docker Desktop on WSL2](docker/README.md#windows-wsl2).

### Agent container ownership

`agent_container.sh` labels every created container and volume with a random
invocation ID. Automatic exit/signal cleanup checks that ID and removes the
container by its immutable Docker ID; a reused task name never proves
ownership. Failed `up` also cleans resources created before the failure.
Successful `up` leaves them for explicit `down`; `run` cleans them on exit.
Existing task containers and build/install/log volumes are refused without
reuse or removal. Use explicit `down` or stale-resource `clean` only for
resources you own. Host operation commands live in the
[Docker skill](../.claude/skills/isaac-ros-docker/SKILL.md#your-own-container).

### Safe launch stopping

`kill_launch.sh -l` lists only ROS `launch`/`run` roots in the selected
container. Stop a listed root with `kill_launch.sh <pid>`, or stop matching
roots directly with `kill_launch.sh --match <literal-command-substring>`.
`ISAAC_ROS_CONTAINER` selects the target, as for `dexec.sh`. There is no force
bypass; PID 1, non-ROS commands and foreign processes are refused.

The helper compares each process's mount namespace and exact cgroup membership
with its own inside the container. Both must match, including with `--pid=host`
and a shared cgroup namespace. Empty command lines (kernel threads) are excluded.
It finds descendants through parent PIDs and sends SIGINT individually through
Linux pidfds after rechecking scope and start time. It never signals a process
group, which could include foreign processes. Python with `pidfd_open` and
`pidfd_send_signal` and a supporting Linux kernel are required; missing support
fails closed. Processes that deliberately move to another namespace/cgroup are
refused; children spawned after the snapshot rely on ROS launch's shutdown.

The release-4.6 CLI's `run_dev.py` defaults to `--pid=host`, and robot
startup requests it explicitly in `isaac-ros-startup/thornbots-start.sh`.
`agent_container.sh` leaves Docker's
private PID namespace default. Host PID visibility never establishes ownership.
The integration regression is `bash tests/test_kill_launch.sh` on macOS with
Colima and the existing `thornbots-mac` image. It creates/removes its own agent
containers in both PID modes; it never operates on the robot.

## Overview

The Isaac ROS Common
repository contains an array of essential packages for building, testing, and using Isaac ROS.

<div align="center"><a class="reference internal image-reference" href="https://media.githubusercontent.com/media/NVIDIA-ISAAC-ROS/.github/release-4.6/resources/isaac_ros_docs/repositories_and_packages/isaac_ros_common/isaac_ros_common_tools.png/"><img alt="Isaac ROS DevOps tools" src="https://media.githubusercontent.com/media/NVIDIA-ISAAC-ROS/.github/release-4.6/resources/isaac_ros_docs/repositories_and_packages/isaac_ros_common/isaac_ros_common_tools.png/" width="auto"/></a></div>

For solutions to known issues, see the [Troubleshooting](https://nvidia-isaac-ros.github.io/troubleshooting/index.html) section.

---

## Documentation

Please visit the [Isaac ROS Documentation](https://nvidia-isaac-ros.github.io/repositories_and_packages/isaac_ros_common/index.html) to learn how to use this repository.

---

## Latest

Update 2026-08-18: Compatibility and integration updates for the Isaac ROS 4.6.0 release
