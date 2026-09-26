#!/bin/bash
# Sourced as root by workspace-entrypoint.sh at container start: puts the
# container user in `dialout` for the DJI UART and the RPLIDAR.
groupadd -f dialout >/dev/null
adduser "${USERNAME}" dialout >/dev/null
