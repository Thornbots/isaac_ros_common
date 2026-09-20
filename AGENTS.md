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

- **A full `colcon build` on the robots takes far too long.** Building all the
  packages on the Orin is minutes of wall clock every time, and the compile
  itself — not rosdep or the image pull — is the bulk of it. Worth attacking:
  ccache in the image, `--packages-up-to`/`--packages-select` instead of a
  whole-workspace rebuild, `Release` without debug symbols, capping the
  parallel-worker count so the Orin doesn't thrash, or shipping prebuilt
  binaries in the image so the robot only rebuilds what changed.

## Open

- **The rplidar udev rule is not installed, and can't be without reclaiming a
  layer.** `docker/udev_rules/98-rplidar.rules` and
  `docker/scripts/hotplug-rplidar.sh` are the authoritative pair, but the
  aarch64 image is at 127 layers against overlay2's ~128 cap, so the `COPY`s
  fail on the robot with `max depth exceeded` (they build fine on x86_64 --
  see `docker/README.md`). The zero-layer path is to install them from the
  bind-mounted `src/` at container start, by extending the entrypoint patch
  that already exists at the top of `Dockerfile.thornbots`. Nothing needs
  `/dev/rplidar` yet, so this is not urgent.

- **`Dockerfile.thornbots` spends 25 layers, 16 of them on tiny `COPY`s.**
  Census of `isaac_ros_dev-aarch64` (2026-09-20, 127 layers total): ~90 come
  from the NVIDIA base image, 6 from `Dockerfile.realsense`, 25 from ours --
  and 16 of ours are the seven `package.xml` COPYs, the seven package COPYs,
  and the two realsense config YAMLs, holding under 20 MB between them.
  Reclaiming ~13 gets back the headroom the rplidar rule needs:
  `COPY --parents */package.xml` for LAYER 4 (one layer, needs the
  `dockerfile:1.7-labs` syntax directive, and keeps the manifests-only
  caching LAYER 4 exists for), a single `COPY .` for LAYER 5 (one more
  `.dockerignore` rule so `isaac_ros_common/docker/` stays out of `src/`),
  and merging LAYER 6's two `echo >> /etc/bash.bashrc` RUNs. Rewriting
  LAYER 4 and 5 forces one full uncached rebuild on every machine, so do it
  between hardware sessions, not before one.

## Committing

This package is a submodule of `thornbots_workspace`, on branch `release-3.2`. Commit
and push here first, then bump this gitlink in `../` — one logical change, one
bump, never a gitlink pointing at an unpushed commit. Full rule in
`../CLAUDE.md` § Packages.
