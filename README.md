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
