#!/bin/bash
# mac-keepalive.sh: keep the Mac container reachable. Run it on the host;
# it (re)creates the tmux session `keepalive` with three windows:
#   docker   - ssh forward ~/.colima/default/docker.sock -> VM's docker.sock
#   foxglove - ssh forward <tailscale IP>:8765 -> the container's bridge
#   watch    - docker-starts the container if it stopped (never creates one);
#              restarts colima only when the VM itself stops answering ssh
# colima's own docker.sock forward rides one ssh ControlMaster nobody
# supervises; these loops replace it and reconnect within seconds.
set -u
SELF="$(realpath "$0")"
source "$(dirname "$SELF")/container.sh"
PORT="${FOXGLOVE_PORT:-8765}"
SSH_CFG="${TMPDIR:-/tmp}/colima_ssh.cfg"
SOCK="$HOME/.colima/default/docker.sock"

t() { perl -e 'alarm shift; exec @ARGV' "$@"; }  # macOS has no timeout(1)
log() { echo "$(date '+%F %T') $*"; }

# ssh into the colima VM: vm_ssh [ssh options...] -- [remote command...].
# Fresh config every call, since the VM's ssh port changes on each colima
# start. ControlMaster=no: never share (or become) colima's ssh.sock master.
vm_ssh() {
    local opts=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do opts+=("$1"); shift; done
    [ $# -gt 0 ] && shift
    t 20 colima ssh-config > "$SSH_CFG" 2>/dev/null || return 1
    ssh -F "$SSH_CFG" -o ControlMaster=no -o ControlPath=none -o BatchMode=yes \
        -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
        -o ExitOnForwardFailure=yes "${opts[@]}" \
        "$(awk '/^Host /{print $2; exit}' "$SSH_CFG")" "$@"
}

container_ip() {
    docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER" 2>/dev/null
}

case "${1:-}" in
docker)
    while true; do
        rm -f "$SOCK"
        log "docker.sock forward up"
        vm_ssh -N -L "$SOCK:/var/run/docker.sock"
        log "docker.sock forward exited ($?), reconnecting"; sleep 2
    done ;;
foxglove)
    while true; do
        TS_IP=$(tailscale ip -4 2>/dev/null | head -1); IP=$(container_ip)
        if [ -z "$TS_IP" ] || [ -z "$IP" ]; then sleep 5; continue; fi
        log "foxglove forward up: ws://$TS_IP:$PORT -> $IP"
        vm_ssh -N -L "$TS_IP:$PORT:$IP:$PORT" &
        pid=$!
        # Reconnect on exit, or when the container's IP moves.
        while kill -0 "$pid" 2>/dev/null; do
            sleep 10
            NEW=$(container_ip)
            if [ -n "$NEW" ] && [ "$NEW" != "$IP" ]; then kill "$pid"; fi
        done
        wait "$pid"; log "foxglove forward exited, reconnecting"; sleep 2
    done ;;
watch)
    misses=0
    while true; do
        if vm_ssh -o ConnectTimeout=10 -- true 2>/dev/null; then
            misses=0
            if t 20 docker info >/dev/null 2>&1 && ! container_running "$CONTAINER"; then
                log "starting $CONTAINER"
                docker start "$CONTAINER" >/dev/null || log "docker start failed"
            fi
        else
            misses=$((misses + 1)); log "VM not answering ssh ($misses/3)"
            if [ "$misses" -ge 3 ]; then
                log "restarting colima"; t 120 colima stop --force; t 600 colima start
                misses=0
            fi
        fi
        sleep 30
    done ;;
"")
    # Replace any earlier session and the forwards it (or a hand-run ssh) left.
    tmux kill-session -t keepalive 2>/dev/null
    pkill -f "ssh -F .*colima_ssh.cfg .*-L" 2>/dev/null
    tmux new -d -s keepalive -n docker "$SELF docker"
    tmux new-window -d -t keepalive -n foxglove "$SELF foxglove"
    tmux new-window -d -t keepalive -n watch "$SELF watch"
    echo "tmux session keepalive: windows docker, foxglove, watch (tmux attach -t keepalive)" ;;
*) echo "usage: $0 [docker|foxglove|watch]" >&2; exit 2 ;;
esac
