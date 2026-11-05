# isaac_ros_common

Follow [workspace rules](../AGENTS.md) and [CI](../docs/CI.md).
Our additions sit on NVIDIA `release-4.6`; do not build upstream interface/test
packages. Read [Docker design/setup](docker/README.md),
[Mac setup](macos/README.md), and the
[Docker skill](../.claude/skills/isaac-ros-docker/SKILL.md) for host operations.
Agents make and remove their own containers with `scripts/agent_container.sh`; the
user runs `isaac-ros activate`. Robot updates default to registry pulls and
offline overlays; local image builds/shipping are emergency fallbacks, not the
default ([registry pull and overlay](docker/README.md#building-the-robots-image)).

## Scope

Own image layout, entry, DDS profiles and domain selection. Put behavior in its
owning package and apt dependencies in `package.xml`, not a Docker layer.
`scripts/` edits are live without rebuilding; `docker/` edits need an image build.

## Open

Software commitments: [ROADMAP](../docs/ROADMAP.md#additional-mini-work).
Physical validation: [ROBOT_TESTS](../docs/ROBOT_TESTS.md#robot-acceptance).

Before a host’s first Jazzy run, check shell initialization for stale Humble setup; the CLI mounts
host `.bashrc` and `.profile`. Mount-policy decisions never authorize credential reads.
