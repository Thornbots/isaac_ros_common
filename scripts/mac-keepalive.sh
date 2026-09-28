#!/bin/bash
# mac-keepalive.sh: run on the Mac host, in tmux. Every 30s it restarts
# colima if docker stops answering (3 misses),
# docker-starts the existing Mac container if it stopped (never creates one),
# and keeps an ssh tunnel from <tailscale IP>:8765 into the container's
# Foxglove bridge, so any launch's bridge is reachable across the tailnet.
#   tmux new -d -s keepalive isaac_ros_common/scripts/mac-keepalive.sh
set -u
source "$(dirname "$(realpath "$0")")/container.sh"
PORT="${FOXGLOVE_PORT:-8765}"
SSH_CFG="${TMPDIR:-/tmp}/colima_ssh.cfg"

t() { perl -e 'alarm shift; exec @ARGV' "$@"; }  # macOS has no timeout(1)
# The tunnel's pid, found by its listener. The tunnel must not share colima's
# ControlMaster (ssh.sock): docker.sock is forwarded over it, and killing a
# tunnel that had become the master cut docker off (2026-09-28).
tunnel_pid() { lsof -t -nP -iTCP@"$1":"$PORT" -sTCP:LISTEN -a -c ssh 2>/dev/null; }
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
            kill $(lsof -t -nP -iTCP:"$PORT" -sTCP:LISTEN -a -c ssh 2>/dev/null) 2>/dev/null
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
    # A container IP change means a stale forward: drop it with the listener.
    if [ -n "$IP" ] && [ "$IP" != "${LAST_IP:-$IP}" ]; then
        kill $(tunnel_pid "$TS_IP") 2>/dev/null; sleep 1
    fi
    LAST_IP=$IP
    if [ -n "$TS_IP" ] && [ -n "$IP" ] && [ -z "$(tunnel_pid "$TS_IP")" ]; then
        colima ssh-config > "$SSH_CFG" 2>/dev/null
        HOST=$(awk '/^Host /{print $2; exit}' "$SSH_CFG")
        if ssh -F "$SSH_CFG" -f -N -o ControlMaster=no -o ControlPath=none \
            -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 \
            -o ServerAliveCountMax=3 -L "$FWD" "$HOST"; then
            log "foxglove tunnel up: ws://$TS_IP:$PORT"
        else
            log "foxglove tunnel failed"
        fi
    fi
    sleep 30
done
