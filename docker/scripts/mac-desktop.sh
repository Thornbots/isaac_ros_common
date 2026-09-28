#!/bin/bash
# mac-desktop.sh: Dockerfile.mac's CMD. Starts Xvnc on :1 (port 5901) with
# openbox, then idles so `docker exec` can launch GUI apps onto DISPLAY=:1.
# VNC password is $VNC_PASSWORD (default "thornbots"); publish the port on
# 127.0.0.1 only. macOS: open vnc://localhost:5901 in Finder or Safari.
set -e
mkdir -p ~/.vnc
echo "${VNC_PASSWORD:-thornbots}" | vncpasswd -f > ~/.vnc/passwd
chmod 600 ~/.vnc/passwd
Xvnc :1 -geometry "${VNC_GEOMETRY:-1920x1080}" -depth 24 -localhost=0 \
    -SecurityTypes VncAuth -PasswordFile ~/.vnc/passwd &
sleep 1
DISPLAY=:1 openbox &
exec sleep infinity
