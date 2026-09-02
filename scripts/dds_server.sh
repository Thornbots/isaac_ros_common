#!/bin/bash
#
# Start the Fast DDS discovery server on the machine that PUBLISHES the data.
# Clients find it via /etc/fastdds/profile.xml (docker/fastdds_cable.xml), which
# lists this machine's tailscale address. Nothing discovers anything until this
# runs, on the publisher, once per boot.
#
#   ./dds_server.sh      start (detached, comes back after a reboot)
#   ./dds_server.sh -f   foreground, logs to the terminal
#   ./dds_server.sh -s   stop and remove
#   ./dds_server.sh -l   is it running, and what is it serving
#
# The server id is derived from this machine's tailscale IP, not passed by hand:
# it has to match the prefix the profile expects, and `-i 1` on the wrong robot
# gives a server every client silently fails to match.
#
set -euo pipefail

PORT=11811
NAME=dds-server
IMAGE="isaac_ros_dev-$(uname -m)"
DOMAIN="${ROS_DOMAIN_ID:-0}"
MODE=start

while getopts "fsl" opt; do
    case $opt in
        f) MODE=foreground ;;
        s) MODE=stop ;;
        l) MODE=list ;;
        *) sed -n '3,15p' "$0" | sed 's/^# \?//'; exit 1 ;;
    esac
done

if [[ $MODE == stop ]]; then
    docker rm -f "$NAME" >/dev/null 2>&1 && echo "stopped $NAME" || echo "$NAME was not running"
    exit 0
fi

if [[ $MODE == list ]]; then
    if docker inspect "$NAME" >/dev/null 2>&1; then
        docker ps -a --filter "name=^/${NAME}$" --format '{{.Names}}  {{.Status}}'
        docker logs "$NAME" 2>&1 | grep -E 'Server (ID|GUID|Addresses)' || true
    else
        echo "$NAME is not running -- clients will see an empty graph"
    fi
    exit 0
fi

TS_IP=$(tailscale ip -4 2>/dev/null | head -1)
if [[ -z "$TS_IP" ]]; then
    echo "ERROR: no tailscale IPv4 address; is tailscaled up?" >&2
    exit 1
fi

# Keep in sync with the <RemoteServer> entries in docker/fastdds_cable.xml.
case "$TS_IP" in
    100.93.23.77)   ID=0 ;;   # ts-nano-standard
    100.89.195.53)  ID=1 ;;   # ts-nano-hero
    100.87.215.118) ID=2 ;;   # ts-nano-sentry
    *)
        echo "ERROR: $TS_IP is not a known publisher." >&2
        echo "       Add it to fastdds_cable.xml with its own server id and" >&2
        echo "       prefix (44.53.<id as 2 hex digits>.5f.45.50.52.4f.53.49.4d.41)," >&2
        echo "       then add the id here." >&2
        exit 1
        ;;
esac

CMD="export ROS_DOMAIN_ID=$DOMAIN; source /opt/ros/humble/setup.bash; exec fastdds discovery -i $ID -l $TS_IP -p $PORT"

if [[ $MODE == foreground ]]; then
    exec docker run --rm --network host --entrypoint bash "$IMAGE" -c "$CMD"
fi

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --restart unless-stopped --name "$NAME" --network host \
    --entrypoint bash "$IMAGE" -c "$CMD" >/dev/null

sleep 3
if [[ -z "$(docker ps -q --filter "name=^/${NAME}$")" ]]; then
    echo "ERROR: server exited immediately:" >&2
    docker logs "$NAME" 2>&1 | tail -10 >&2
    exit 1
fi
echo "discovery server up: id=$ID  $TS_IP:$PORT  domain=$DOMAIN"
echo "restart policy is unless-stopped, so it returns on its own after a reboot."
