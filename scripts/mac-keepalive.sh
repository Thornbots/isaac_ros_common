#!/bin/bash
# mac-keepalive.sh: run on the Mac host, in tmux. Every 30s it restarts
# colima if docker stops answering (3 misses: the vz VM has frozen before),
# docker-starts the existing Mac container if it stopped (never creates one),
# and keeps an ssh tunnel from <tailscale IP>:8765 into the container's
# Foxglove bridge, so any launch's bridge is reachable across the tailnet.
#   tmux new -d -s keepalive isaac_ros_common/scripts/mac-keepalive.sh
set -u
source "$(dirname "$(realpath "$0")")/container.sh"
PORT="${FOXGLOVE_PORT:-8765}"
SSH_CFG="${TMPDIR:-/tmp}/colima_ssh.cfg"

t() { perl -e 'alarm shift; exec @ARGV' "$@"; }  # macOS has no timeout(1)
log() { echo "$(date '+%F %T') $*"; }

misses=0
while true; do
    if t 20 docker info >/dev/null 2>&1; then
        misses=0
    else
        misses=$((misses + 1))
        log "docker not answering ($misses/3)"
        if [ "$misses" -ge 3 ]; then
            log "restarting colima"
            pkill -f "ssh.*:$PORT:" 2>/dev/null
            t 120 colima stop --force; t 600 colima start
            misses=0
        fi
        sleep 30; continue
    fi

    if ! container_running "$CONTAINER"; then
        log "starting $CONTAINER"
        docker start "$CONTAINER" >/dev/null || log "docker start failed"
    fi

    TS_IP=$(tailscale ip -4 2>/dev/null | head -1)
    IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER" 2>/dev/null)
    FWD="$TS_IP:$PORT:$IP:$PORT"
    if [ -n "$TS_IP" ] && [ -n "$IP" ] && ! pgrep -f "ssh.*-L $FWD" >/dev/null; then
        pkill -f "ssh.*:$PORT:" 2>/dev/null
        colima ssh-config > "$SSH_CFG" 2>/dev/null
        HOST=$(awk '/^Host /{print $2; exit}' "$SSH_CFG")
        if ssh -F "$SSH_CFG" -f -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 \
            -o ServerAliveCountMax=3 -L "$FWD" "$HOST"; then
            log "foxglove tunnel up: ws://$TS_IP:$PORT"
        else
            log "foxglove tunnel failed"
        fi
    fi
    sleep 30
done
