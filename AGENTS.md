# isaac_ros_common

Follow [workspace rules](../AGENTS.md) and [CI](../docs/CI.md).
Our additions sit on NVIDIA `release-4.6`; do not build upstream interface/test
packages. Read [Docker design/setup](docker/README.md),
[Mac setup](macos/README.md), and the
[Docker skill](../.claude/skills/isaac-ros-docker/SKILL.md) for host operations.
On the laptop, agents attach only; the user runs `isaac-ros activate` and image builds.

## Scope

Own image layout, entry, DDS profiles and domain selection. Put behavior in its
owning package and apt dependencies in `package.xml`, not a Docker layer.
`scripts/` edits are live without rebuilding; `docker/` edits need an image build.

## Open

- Before a host's first Jazzy run, check shell initialization for stale Humble
  setup; the CLI mounts host `.bashrc` and `.profile` into the container.
- Stock `.isaac_ros_dev-dockerargs` mounts host config and credential directories.
  Decide whether robots should replace it with an empty file; this does not
  authorize reading credentials.
- Container rplidar hotplug/udev acceptance remains in
  [hardware status](../JAZZY_FLASH.md#hardware-status).
- Robot build speed: [ROADMAP track C](../ROADMAP.md#c-jazzy-on-the-robots).
- Native Mac GUI rendering remains unverified; use [hardware status](../JAZZY_FLASH.md#hardware-status).
