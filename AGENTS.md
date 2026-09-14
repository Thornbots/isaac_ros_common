# isaac_ros_common: agent notes

Vendored fork of
[NVIDIA-ISAAC-ROS/isaac_ros_common](https://github.com/NVIDIA-ISAAC-ROS/isaac_ros_common).
**This repo's default branch is `release-3.2`, not `main`** — commit there. It
holds the container: the Dockerfile chain, the build and exec scripts, the DDS
profiles, and the udev rules. The ROS packages in the top level
(`isaac_ros_test`, the `*_interfaces` packages, …) are upstream's and we don't
build them.

**Read [`.claude/skills/isaac-ros-docker`](../.claude/skills/isaac-ros-docker/)
before running anything here**, and
[`docker/README.md`](docker/README.md) before changing `Dockerfile.thornbots`.
That file covers the build context, why the seven packages share one layer, what
LAYER 4's rosdep pass can and can't resolve, and why `sim` is left out.

Unlike the other packages, this one is **not** copied into `/workspaces/ros2_ws`,
so the shadowing trap doesn't apply. But `scripts/` and `docker/` are read from
`src/` at container-launch time, so an edit takes effect on the next `run_dev.sh`
or `dexec.sh` with no rebuild.

## Keep the fork diff small

Everything outside `docker/Dockerfile.thornbots`, `docker/README.md`,
`docker/config/`, `docker/udev_rules/98-rplidar.rules`,
`docker/scripts/hotplug-rplidar.sh`, `docker/fastdds_cable.xml`,
`scripts/dexec.sh`, and `scripts/kill_launch.sh` is upstream code we want to be
able to re-merge from a newer Isaac ROS release. Add Thornbots behavior in a new
file rather than editing an upstream one where you have the choice.

## Scope

- Owns image layout, container entry, the FastDDS profile, and
  the `ROS_DOMAIN_ID`. Nothing about robot behavior.
- Node code, launch files, and tuning belong to the package that owns them.
  Adding an apt dependency for a package means editing that package's
  `package.xml`, not hardcoding it into a layer here.

## Open

- **The rplidar udev rule and hotplug script are dead weight.** No Dockerfile
  copies `docker/udev_rules/98-rplidar.rules` to `/etc/udev/rules.d/` or
  `docker/scripts/hotplug-rplidar.sh` to `/opt/rplidar/` (`Dockerfile.realsense`
  does exactly that for its RealSense equivalents). A second, diverged copy of
  both lives in `../sllidar_ros2/scripts/`. Decide which copy is authoritative
  and either install it or delete it.
