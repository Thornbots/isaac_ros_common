# The workspace natively on a Mac

Sim, the benches and their gz and rviz windows on an Apple Silicon Mac,
from [RoboStack](https://robostack.github.io/)'s Jazzy packages. No Isaac
ROS, CUDA or YOLO, as in `../docker/Dockerfile.mac`, but no container, no
VNC and no Foxglove needed to watch.

## Set up

With [pixi](https://pixi.sh) (`brew install pixi`), from this directory:

```bash
pixi install      # the ROS env, into .pixi/
pixi run build    # colcon build of ../.. into build/ and install/
```

The container shares `ros2_ws/build` and `install`; these are separate.

## Run

```bash
pixi shell
source install/setup.bash
ros2 launch sim estimation.launch.py
ros2 launch sim shot_hit.launch.py
ros2 launch sim localization_tests.launch.py
```

`headless:=true` drops the windows. Foxglove still serves on port 8765.

## What differs from Linux

`pixi.toml` sets each of these in the env:

- `LDFLAGS=-Wl,-dead_strip_dylibs`. Every C++ node otherwise links the
  message packages' Python bindings, which abort it at load on macOS.
- `FASTDDS_BUILTIN_TRANSPORTS=UDPv4`. Fast DDS's shared memory paces the
  benches at ~1.7x here, against ~20x on UDP.
- `python/sitecustomize.py`. SIP strips `DYLD_LIBRARY_PATH` from every
  Python node (their `#!/usr/bin/env` shebang), so they can't load our
  message libraries; it rebuilds the path and re-execs once.

A launch killed hard (`kill -9`) leaves its nodes running: macOS has no
`PR_SET_PDEATHSIG`. Ctrl-C stops them.
