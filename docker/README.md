# `Dockerfile.thornbots`

The Thornbots top layer over Isaac ROS, built as
`ros2_humble.realsense.thornbots` (see `scripts/.isaac_ros_common-config`).
It installs the Isaac ROS apt packages this project needs, patches the
RealSense config YAMLs to 60 fps, and builds our seven packages into
`/workspaces/ros2_ws`.

## Build context is `src/`, not `docker/`

`run_dev.sh` passes `--context_dir "$ROOT/../.."` to `build_image_layers.sh`,
which applies it to the last layer only — the other Dockerfiles in the chain
still build against `docker/`. So every `COPY` path in `Dockerfile.thornbots`
is relative to `isaac_ros-dev/src/`, and building it by hand means:

```bash
cd ~/workspaces/isaac_ros-dev/src
docker build -f isaac_ros_common/docker/Dockerfile.thornbots -t thornbots:latest .
```

`src/.dockerignore` keeps `.git` and build artifacts out; the context is
~35 MB rather than ~155 MB.

## Sources come from the submodules

Our packages are `COPY`ed from the checked-out git submodules in `src/`. They
used to be `git clone`d during the build, with `RECLONE_*` build args to bust
the cache per package; both are gone (changed 2026-09-08).

The baked copy therefore tracks whatever the submodules are checked out at,
**including uncommitted local edits**. That cuts both ways: your edit is in the
image without any commit, and a teammate's clone at a stale gitlink builds the
old code no matter how current the package remote is.

`git submodule update` does **not** make the image match the remotes — it
rewinds each submodule to the SHA the superproject has recorded, detaching HEAD.
Run it on a package you committed but didn't bump the gitlink for and your work
leaves the working tree silently (`git -C <pkg> checkout <branch>` gets it
back). To sync against the remotes, use `git submodule update --remote`, which
follows the `branch` key in `src/.gitmodules`.

## Why one layer for all seven packages

They share a single `COPY` group and a single `colcon build` (LAYER 5), so
touching any one of them rebuilds all seven. The per-package layers this
replaced didn't buy much: the packages move together, so bumping an early one
already invalidated every layer after it, and the sequential builds gave up
colcon's cross-package parallelism. One invocation also lets colcon
topologically order the build instead of the layer order hardcoding it.

Their dependencies stay in their own layer (LAYER 4), since colcon skips
`exec_depends` and a source edit shouldn't re-run a few hundred MB of apt.

When iterating on one package, don't rebuild the image at all — `colcon build`
inside the running container is far faster.

## LAYER 4: rosdep, and the three things it can't do

LAYER 4 copies **only the seven `package.xml` manifests**, then runs

```
rosdep install -y --from-paths $ROS_WS/src --ignore-src --rosdistro humble \
    --skip-keys "realsense2_camera realsense2_camera_msgs"
```

Manifests-only is what makes the layer cache: editing source doesn't touch a
`package.xml`, so the dependency install is skipped. `--ignore-src` covers the
inter-package deps (`thornbots_pkg` → `sentry_localization` → `rf2o_laser_odometry`,
etc.), which resolve locally because all seven manifests are present.

`rosdep` itself is already initialized by `Dockerfile.ros2_humble` (lines
135-140), including NVIDIA's `extra_rosdeps.yaml`, so the `isaac_ros_*` keys
resolve to the apt packages LAYER 2 already installed.

This replaced a hand-maintained apt list (changed 2026-09-08). Two things
still can't come from the manifests:

**`--skip-keys realsense2_camera realsense2_camera_msgs`.** `Dockerfile.realsense`
builds these from source with bloom and deliberately strips the
`ros-humble-librealsense2` dependency from the generated debian control file
(line 41) so they link against the librealsense *it* built from source. Letting
rosdep satisfy those keys from apt would install the stock debs over the custom
ones and pull apt's librealsense2 alongside the source build. Two packages
declare `realsense2_camera`, so without the skip this happens on every build.

**The `diagnostic-updater` version floor**, below — rosdep resolves a key to a
package name, never to a version constraint.

The old hand-kept list also carried `rviz2`, `joint_state_publisher` and
`joint_state_publisher-gui`, which no manifest in the image declares. All three
are gone from LAYER 4 (2026-09-08). Only the `-gui` one actually leaves the
image: `Dockerfile.ros2_humble` already installs `rviz2` (twice, lines 125 and
218) and `joint_state_publisher` (line 199), along with `slam_toolbox` and
`robot_state_publisher` — so much of the old list was shadowing the base layer.
Nothing in the workspace launches `joint_state_publisher_gui`; if you want it
back for URDF work, `apt-get install ros-humble-joint-state-publisher-gui` in
the container.

## The `diagnostic-updater` version floor

`ros-humble-diagnostic-updater` is pinned to `>= 4.0.7` deliberately. 4.0.6 is
a header-only build that ships no `libdiagnostic_updater.so` at all, so any
node linking it dies at startup with

```
error while loading shared libraries: libdiagnostic_updater.so
```

and exit code 127. It's a transitive dep of both `robot_localization`
(`ekf_node`) and `nav2_lifecycle_manager`, so a bad version silently takes out
the `ekf` and `amcl` localization modes while `slam` keeps working — which
reads like a localization regression rather than a packaging problem. This bit
the project twice, 2026-07-20 and 2026-07-25.

The constraint goes through `apt-get satisfy`, not `apt-get install`:
`pkg (>= ver)` is Debian control-file dependency syntax, and `apt-get install`
treats the whole string as a package name and fails with `Unable to locate
package ros-humble-diagnostic-updater (>`.

## `sim` is deliberately not in the image

Real hardware never launches gz-sim, so neither `sim`'s dependencies (LAYER 2b,
commented out) nor the package itself is baked in. This makes `sim` the one
first-party package with no `/workspaces/ros2_ws` shadow copy, so `src/sim`
edits are live immediately. A fresh container needs this once before its
first sim launch:

```bash
sudo isaac_ros_common/docker/scripts/install-sim.sh
```

## Directory name vs. ROS package name

Three don't match, which is why LAYER 5 lists packages explicitly:

| directory in `src/` | ROS package |
|---|---|
| `ros2_dji_serial_bridge` | `dji_serial_bridge` |
| `Realsense_ROI_Depth_Rectifier` | `roi_depth_query` |
| `realsense-yolov8-nitros-bridge` | `realsense_yolov8_nitros_bridge` |

The other four (`sllidar_ros2`, `rf2o_laser_odometry`, `sentry_localization`,
`thornbots_pkg`) are the same in both.

`rf2o_laser_odometry` is a Thornbots fork, not upstream — upstream caches the
lidar→base transform at startup, which breaks on our panning head. See
`sentry_localization/README.md`.
