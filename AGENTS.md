# isaac_ros_common: agent notes

**Branch `main`**: upstream
[NVIDIA-ISAAC-ROS/isaac_ros_common](https://github.com/NVIDIA-ISAAC-ROS/isaac_ros_common)
`release-4.6` with our container files on top; the workspace tracks it.
`humble` holds the Humble tree (from `release-3.2`), frozen since
2026-09-27. Upstream's
top-level ROS packages (`isaac_ros_test`, the `*_interfaces`, …) are theirs
and we don't build them.

Upstream 4.x ships no `docker/` or `scripts/`: `isaac-ros-cli` builds and
starts the container. Our files:

- `docker/Dockerfile.thornbots`, the top layer. Read
  [`docker/README.md`](docker/README.md) before changing it.
- `docker/config/`, `docker/fastdds_cable.xml`, the rplidar udev rule and
  hotplug script, `docker/scripts/entrypoint_additions/`,
  `docker/scripts/install-sim.sh`.
- The CLI config: `.isaac-ros-cli/config.yaml`,
  `scripts/.isaac_ros_common-config`, `scripts/.build_image_layers.yaml`,
  linked into place by `scripts/setup_workspace.sh`.
- `scripts/dexec.sh`, `scripts/kill_launch.sh`,
  `scripts/install_isaac_ros_cli.sh`, `scripts/build_robot_image.sh` (the
  robots' image, built on a robot, the Mac, or the x86 laptop under QEMU,
  `docker/README.md`; the user runs it).
- `docker/Dockerfile.mac` (+ `.dockerignore`): sim
  on an Apple Silicon Mac, no Isaac ROS. Standalone; the CLI never builds
  it, so building it on the Mac is fine. `docker/README.md` has the steps.
- `macos/`: the workspace natively on the Mac from RoboStack (pixi), gz and
  rviz windows on its screen. `macos/README.md` has the steps and what
  differs from Linux.
  Nobody has seen those windows rendered yet: on 2026-09-30 macOS listed
  rviz2 and the gz GUI as open apps, but the display was asleep and
  `screencapture` came back black.

**Read [`.claude/skills/isaac-ros-docker`](../.claude/skills/isaac-ros-docker/)
before running anything here.** Agents never run `isaac-ros activate` in any
form, nor build the image; the user does. `reference.md` there lists where
the CLI reads each config file, taken from its source.

Not copied into `/workspaces/ros2_ws`, so the shadowing trap doesn't apply.
`scripts/` is read from `src/` at run time, so a `dexec.sh` edit takes effect
with no rebuild; `docker/` edits need one.

## Host setup

- Ubuntu hosts: the `isaac-ros-cli` apt package (`release-4`, `noble`;
  `noble-jetpack` on Jetson), then `sudo isaac-ros init docker`. The
  robots get it, and the rest of their host setup, from
  `scripts/jetson_setup.sh`; `scripts/jetson_trim.sh` then makes them
  headless.
- **A cold `--build-local` rebuilds every layer.** The CLI skips a layer
  only when `docker manifest inspect` finds its tag in a registry, so
  `docker load`ing another machine's layers skips nothing, and loaded
  images carry no BuildKit cache (ts-nano-sentry, 2026-09-30).
- The Arch laptop and the Mac have no apt: `scripts/install_isaac_ros_cli.sh` installs
  release-4.6 under `~/.local/share/isaac-ros-cli` with no root, and
  `~/.local/bin/isaac-ros` runs it.
- **The CLI starts the container with `--gpus all`, which Docker 28+
  resolves through the CDI spec in `/etc/cdi/nvidia.yaml`.** A stale spec
  still passes the GPU device nodes through (`--privileged`), but no driver
  libraries: no `libcuda`, no `libEGL_nvidia`, so gz and rviz fall back to
  Mesa's software GL and CUDA nodes can't start. Arch's
  `nvidia-container-toolkit` ships no refresh unit, so regenerate after
  every driver update: `sudo nvidia-ctk cdi generate
  --output=/etc/cdi/nvidia.yaml`, then restart the container. `smoke.sh`
  step 1 checks for it. Humble's `run_dev.sh` used `--runtime nvidia`,
  which never reads CDI.
- Then, per workspace, `scripts/setup_workspace.sh`, and run the CLI with
  `ISAAC_ROS_WS` set to that workspace. The laptop's `~/.zshrc` exports the
  Humble one.
- On the laptop the Jazzy workspace is `~/workspaces/isaac_ros-jazzy` and
  its container `isaac_ros_jazzy_container`. `~/workspaces/isaac_ros-dev`
  and `isaac_ros_dev-x86_64-container` are the frozen Humble ones. The scripts read the name from
  `.isaac-ros-cli/config.yaml`; `ISAAC_ROS_CONTAINER` overrides.

## Scope

- Owns image layout, container entry, the FastDDS profile, and the
  `ROS_DOMAIN_ID` (1 until the cutover). Nothing about robot behavior.
- Node code, launch files, and tuning belong to the package that owns them.
  A package's apt dependency goes in its `package.xml`, not in a layer here.

## Open

- **The CLI mounts the host's `~/.bashrc` and `~/.profile` read-only** into
  `/home/admin`, so container shells source them. The laptop's `.profile`
  sources `~/.cargo/env`, which prints a harmless error on every
  `dexec.sh` call; a robot `.bashrc` that sources `/opt/ros/humble` would
  be worse. Check each host's dotfiles before its first Jazzy run.
- **The stock `.isaac_ros_dev-dockerargs` mounts `~/.config` read-write** (and
  `~/.ssh`, `~/.aws`, `~/.cache`) on apt installs. The laptop's user install
  has no such file. Decide on the robots whether to ship an empty
  `scripts/.isaac_ros_dev-dockerargs`, which replaces it.
- **The rplidar udev rule is installed but untested** in a container. On
  the host, `jetson_setup.sh` installs sllidar_ros2's rule (`/dev/rplidar`,
  0666).
- **Full `colcon build` on the robots is slow.** Ideas: ccache in the image,
  `--packages-up-to` instead of whole-workspace builds, capping workers on
  the Orin, shipping more prebuilt in the image. The image's own colcon
  layer (7 packages) took 172 s on `ts-nano-dev` (2026-10-03, ROADMAP T29);
  a whole-workspace build on JetPack 7.2 is still untimed (JAZZY_PLAN.md
  step 5).

## Committing

This package is a submodule of `thornbots_workspace`. Commit and push here
first, then bump the gitlink in `../`: one logical change, one bump, never a
gitlink pointing at an unpushed commit. Full rule in `../CLAUDE.md` §
Packages.

## CI

GitHub CI runs on pushes and PRs outside frozen Humble branches. Shared lint
is pinned to workspace `13d5965558a3`. Existing diagnostics are recorded in
`.github/quality-baseline.json`; new diagnostics fail. Do not expand the
baseline to hide regressions. Syntax errors always fail.
GPU/CUDA builds require the workspace's manual `ROS Jazzy` workflow and a
provisioned `isaac-ros-jazzy` runner; GitHub-hosted lint still runs on every PR.
