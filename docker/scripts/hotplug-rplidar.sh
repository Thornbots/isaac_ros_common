#!/usr/bin/env bash

# Copied from nvidia realsense hotplug script and "modified" for rplidar

# This script is triggered when a corresponding udev rule is matched with action 

function usage() {
	echo "Usage: hotplug-rplidar.sh -a <action=add/remove> -d <dev_path> [options]"
	echo "-a | --action         Action determines whether the device has been added or removed. Valid values are 'add' or 'remove'."
	echo "-d | --dev-path       Device path that will be used to mount the device."
	echo "-M | --major-version  The kernel major number for the device. This will be used when action=add."
	echo "-m | --minor-version  The kernel minor number for the device. This will be used when action=add."
	echo "-h | --help           Display this message."
}

function timestamp() {
    echo "[$EPOCHREALTIME] [$(date)]"
}

ARGUMENTS=$(getopt -n hotplug-rplidar.sh -o a:d:M:m:h -l action:,dev-path:,major-version:,minor-version:,help -- "$@")
eval set -- "$ARGUMENTS"

while true; do
    case "$1" in
        -a|--action) ACTION="$2"; shift 2 ;;
        -d|--dev-path) DEV_PATH="$2"; shift 2 ;;
        -M|--major-version) MAJOR_VERSION="$2"; shift 2 ;;
        -m|--minor-version) MINOR_VERSION="$2"; shift 2 ;;
        -h|--help) echo "Usage: $0 -a <add/remove> -d <dev_path>"; exit 0 ;;
        --) shift; break ;;
        *) shift ;;
    esac
done

if [[ -z "$ACTION" || -z "$DEV_PATH" ]]; then
    echo "Missing mandatory parameters" >&2
    exit 1
fi

if [[ "$ACTION" == "add" ]]; then
    # Create the device node (symlink already handled by udev)
    if [[ ! -e "$DEV_PATH" ]]; then
        mknod -m 666 "$DEV_PATH" c "$MAJOR_VERSION" "$MINOR_VERSION"
        chown root:plugdev "$DEV_PATH"
        echo "$(timestamp) Added $DEV_PATH with major $MAJOR_VERSION minor $MINOR_VERSION" >> /tmp/docker_usb.log
    fi
elif [[ "$ACTION" == "remove" ]]; then
    if [[ -e "$DEV_PATH" ]]; then
        rm -f "$DEV_PATH"
        echo "$(timestamp) Removed $DEV_PATH" >> /tmp/docker_usb.log
    fi
else
    echo "Unknown action: $ACTION" >&2
    exit 1
fi

