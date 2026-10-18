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
- Windows: [Docker in WSL2](docker/README.md#windows-wsl2).

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
