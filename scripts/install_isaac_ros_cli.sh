#!/bin/bash
# install_isaac_ros_cli.sh: isaac-ros-cli for the current user, no root, on
# hosts without its apt package (the Arch laptop). Ubuntu hosts use apt:
#   sudo apt-get install isaac-ros-cli && sudo isaac-ros init docker
# The CLI hardcodes /etc, /usr/lib and /usr/share paths. This copies it under
# $PREFIX and rewrites those paths in its Python only; the Dockerfiles are
# untouched, so image hashes match an apt install. Needs git and uv.
# Result: ~/.local/bin/isaac-ros, in docker mode. Safe to re-run.
set -euo pipefail

REF="${ISAAC_ROS_CLI_REF:-release-4.6}"
PREFIX="${ISAAC_ROS_CLI_PREFIX:-$HOME/.local/share/isaac-ros-cli}"
SRC="$PREFIX/src"

if [ -d "$SRC/.git" ]; then
    git -C "$SRC" fetch -q origin "$REF" && git -C "$SRC" checkout -q FETCH_HEAD
else
    git clone -q -b "$REF" https://github.com/NVIDIA-ISAAC-ROS/isaac-ros-cli.git "$SRC"
fi

rm -rf "$PREFIX/etc" "$PREFIX/lib" "$PREFIX/share"
mkdir -p "$PREFIX/etc" "$PREFIX/lib" "$PREFIX/share"
cp -r "$SRC/docker" "$SRC/config/.build_image_layers.yaml" \
    "$SRC/config/.isaac_ros_common-config" "$PREFIX/etc/"
echo "ISAAC_ROS_ENVIRONMENT=docker" > "$PREFIX/etc/environment.conf"  # isaac-ros init docker
cp "$SRC/config/config.yaml" "$PREFIX/share/"
cp -r "$SRC/src/isaac_ros_cli" "$SRC"/scripts/run_dev/*.py "$PREFIX/lib/"
grep -rlZ --include='*.py' -e /etc/isaac-ros-cli -e /usr/lib/isaac-ros-cli \
    -e /usr/share/isaac-ros-cli "$PREFIX/lib" | xargs -0 sed -i \
    -e "s|/etc/isaac-ros-cli|$PREFIX/etc|g" \
    -e "s|/usr/lib/isaac-ros-cli|$PREFIX/lib|g" \
    -e "s|/usr/share/isaac-ros-cli|$PREFIX/share|g"

# Noble's python and pydantic 1.x, which the CLI's validator is written for.
uv venv -q --allow-existing --python 3.12 "$PREFIX/venv"
uv pip install -q --python "$PREFIX/venv/bin/python" 'click>=8' 'pydantic<2' termcolor pyyaml

mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/isaac-ros" <<WRAPPER
#!/bin/sh
# isaac-ros-cli $REF, user install (isaac_ros_common/scripts/install_isaac_ros_cli.sh).
# venv first on PATH: the CLI runs run_dev.py through /usr/bin/env python3.
export PATH="$PREFIX/venv/bin:\$PATH" PYTHONPATH="$PREFIX/lib" ISAAC_ROS_CLI_ETC="$PREFIX/etc"
exec python3 -c 'import sys; from isaac_ros_cli.cli import main; sys.argv[0] = "isaac-ros"; sys.exit(main())' "\$@"
WRAPPER
chmod +x "$HOME/.local/bin/isaac-ros"
echo "installed: $HOME/.local/bin/isaac-ros ($REF at $(git -C "$SRC" rev-parse --short HEAD))"
