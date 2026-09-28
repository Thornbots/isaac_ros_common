# `Dockerfile.thornbots`

The Thornbots top layer over Isaac ROS 4.6 on ROS 2 Jazzy. `isaac-ros-cli`
builds the chain `isaac_ros` -> `realsense` -> `thornbots`: the first two
Dockerfiles ship with the CLI, this one is ours. It installs the Isaac ROS apt
packages we use, builds our seven packages into `/workspaces/ros2_ws`, and
drops in the 60 fps RealSense profiles, the DDS profile and the rplidar udev
rule.

## Building

On the host, once per clone, then build and start:

```bash
src/isaac_ros_common/scripts/setup_workspace.sh
export ISAAC_ROS_WS=~/workspaces/isaac_ros-dev   # the workspace holding this src/
isaac-ros activate --build-local
```

`setup_workspace.sh` links `scripts/`, `.isaac-ros-cli/` and
`scripts/.build_image_layers.yaml` to where the CLI reads them; its header
lists the three paths. Without it the CLI finds none of our config and starts
a stock image.

The image tag is `nvcr.io/nvidia/isaac/ros:isaac_ros-realsense-thornbots_<hash>-<platform>`,
where `<hash>` covers the three Dockerfiles and the apt build args, **not the
package sources**. So after a package edit, `activate` finds the old image and
starts it. To bake the edit in, remove that tag and build again; BuildKit's
cache reruns only the layers whose inputs changed:

```bash
docker rmi nvcr.io/nvidia/isaac/ros:isaac_ros-realsense-thornbots_<hash>-amd64
isaac-ros activate --build-local
```

`--no-cache` also rebuilds the `isaac_ros` and `realsense` layers from
scratch, which takes much longer.

`isaac-ros activate` exits 0 even when the build fails. Read the output.

## Build context is `src/`, not `docker/`

`scripts/.build_image_layers.yaml` sets `context_overrides: thornbots: ../..`,
relative to this directory. Every `COPY` path in `Dockerfile.thornbots` is
relative to `isaac_ros-dev/src/`, and `src/.dockerignore` keeps `.git`,
build artifacts, `sim/` and everything in `isaac_ros_common/` except
`docker/` out of the context.

Building it by hand (the base is the CLI's realsense layer):

```bash
cd ~/workspaces/isaac_ros-dev/src
docker build -f isaac_ros_common/docker/Dockerfile.thornbots \
    --build-arg BASE_IMAGE=<realsense image> -t thornbots:latest .
```

## Sources come from the submodules

Packages are `COPY`ed from the checked-out submodules, **uncommitted edits
included**. A teammate's clone at a stale gitlink builds the old code no
matter how current the package remote is. `git submodule update` rewinds each
submodule to the recorded SHA and detaches HEAD; `git submodule update
--remote` follows the `branch` key in `src/.gitmodules`.

## Layers

| layer | what | reruns when |
|---|---|---|
| 1 | apt: build tools and the `ros-jazzy-isaac-ros-*` packages | this file changes |
| 2 | `COPY --parents */package.xml`, then `rosdep install` | a `package.xml` changes |
| 3 | `COPY` of every package, then one `colcon build` | any source changes |
| 4 | `COPY` of `docker/`, then one `RUN` that installs the config files | anything in `docker/` changes |

`--parents` and `--exclude` need the `dockerfile:1.7-labs` syntax line at the
top. Layer 3 excludes `isaac_ros_common/` and the top-level `*.md` files, so
editing a plan doesn't rebuild the packages.

All seven packages share one `colcon build`, so touching one rebuilds all
seven. The packages move together anyway, and one invocation lets colcon order
and parallelise them. When iterating on one package, `colcon build` inside the
running container instead.

The Humble image sat at 127 of overlay2's ~128 layers on aarch64, 25 of them
from this file. On x86_64 (2026-09-26) the Jazzy image is 42: `isaac_ros` 25,
`realsense` 9, this file 8 (the four above plus a 4 kB `WORKDIR`). Check
headroom with
`docker inspect <image> --format '{{len .RootFS.Layers}}'`.

## rosdep and `--skip-keys`

Layer 2 runs

```
rosdep install -y --from-paths $ROS_WS/src --ignore-src --rosdistro jazzy \
    --skip-keys "realsense2_camera realsense2_camera_msgs"
```

The CLI's `Dockerfile.realsense` builds `realsense2_camera` from source with
bloom and strips the `ros-jazzy-librealsense2` dependency so it links against
the librealsense it built. Letting rosdep resolve those keys from apt could
pull the stock debs over the custom ones. `--ignore-src` covers the
inter-package deps, which resolve because all seven manifests are present.

The Humble image pinned `ros-humble-diagnostic-updater >= 4.0.7` because 4.0.6
shipped no `libdiagnostic_updater.so`. Jazzy ships 4.2.x, so the pin is gone.

## Container user, udev, environment

- `dialout`: `scripts/entrypoint_additions/50-dialout.sh`, which the CLI's
  `workspace-entrypoint.sh` sources as root at container start.
- `udev_rules/98-rplidar.rules` and `scripts/hotplug-rplidar.sh` go to
  `/etc/udev/rules.d/` and `/opt/rplidar/`.
- `/etc/bash.bashrc` gets `ROS_DOMAIN_ID` (build arg, default 1 until the
  Jazzy cutover), the FastDDS profile, `rmw_fastrtps_cpp`, and the Jazzy and
  `ros2_ws` setup files.

## `sim` is deliberately not in the image

Real hardware never launches gz-sim, so `sim` and its dependencies stay out.
It is the one first-party package with no `/workspaces/ros2_ws` copy, so
`src/sim` edits are live immediately. A fresh container needs this once
before its first sim launch:

```bash
sudo isaac_ros_common/docker/scripts/install-sim.sh
```

## Directory name vs. ROS package name

| directory in `src/` | ROS package |
|---|---|
| `ros2_dji_serial_bridge` | `dji_serial_bridge` |
| `Realsense_ROI_Depth_Rectifier` | `roi_depth_query` |
| `realsense-yolov8-nitros-bridge` | `realsense_yolov8_nitros_bridge` |

The other four (`sllidar_ros2`, `rf2o_laser_odometry`, `sentry_localization`,
`thornbots_pkg`) match. `rf2o_laser_odometry` is a Thornbots fork: upstream
caches the lidar-to-base transform at startup, which breaks on our panning
head (see `sentry_localization/README.md`).

# `Dockerfile.mac`

An arm64 image for Apple Silicon Macs without Isaac ROS, CUDA or YOLO. It
runs `sim`, localization and the aiming and estimation benches. It holds
dependencies only: bind-mount the workspace and build inside the container.
gz and rviz render on Mesa llvmpipe (Docker on macOS passes no GPU) into a
VNC desktop.

On the Mac, with Homebrew:

```sh
brew install colima docker docker-buildx
colima start --vm-type vz --cpu 10 --memory 24 --disk 120
# add "cliPluginsExtraDirs": ["/opt/homebrew/lib/docker/cli-plugins"] to ~/.docker/config.json
cd <workspace>/src
docker buildx build --load -t thornbots-mac -f isaac_ros_common/docker/Dockerfile.mac .
docker run -d --name thornbots_mac --shm-size=2g -p 127.0.0.1:5901:5901 \
    -v <workspace>:/workspaces/isaac_ros-dev thornbots-mac
```

The workspace is the directory holding `src/`. Open `vnc://localhost:5901`
in Finder (Cmd-K), password `thornbots`, to see the desktop. Then:

```sh
docker exec -it thornbots_mac bash
colcon build --symlink-install --base-paths src/sim src/thornbots_pkg \
    src/sentry_localization src/rf2o_laser_odometry src/ros2_dji_serial_bridge \
    src/sllidar_ros2 src/Realsense_ROI_Depth_Rectifier
source install/setup.bash
ros2 launch sim localization_tests.launch.py
```

`--base-paths` leaves out `realsense-yolov8-nitros-bridge` (it needs Isaac
ROS) and `isaac_ros_common`'s upstream packages. `Dockerfile.mac.dockerignore`
keeps the YOLO bridge's manifest out of rosdep for the same reason.
