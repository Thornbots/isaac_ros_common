#!/usr/bin/env bash
# agent_container.sh -- one throwaway Isaac ROS container per agent task.
#
#   agent_container.sh up    <task> [-w SRC] [-e EVIDENCE] [-c CPUS] [-m MEM] [-i IMAGE] [-d DOMAIN]
#   agent_container.sh run   <task> [same options] -- <cmd...>   # up, run, down (trap)
#   agent_container.sh down  <task>
#   agent_container.sh env   <task>      # export lines for dexec.sh/smoke.sh
#   agent_container.sh ls
#   agent_container.sh clean [-t HOURS] [-n]   # stale labelled containers only
#
# Container isaac-agent-<task>, labelled thornbots.agent=<task>, is made from
# the image the user's container runs (laptop) or thornbots-mac (Mac mini).
# Isolation is enforced here, not by convention:
#   - ROS_DOMAIN_ID (100-199) and GZ_PARTITION (agent-<task>-<domain>) are
#     allocated under a lock and refused when any labelled container has them;
#     sim's MCB PTY link derives from both (/tmp/mcb_emulator_pty-<part>-<dom>).
#   - bridge network, private IPC, no published ports, not privileged: the
#     user's host-network container and other agents cannot see its sockets.
#   - mounts: SRC at .../isaac_ros-dev/src (default: the checkout holding this
#     script; refused if it is $ISAAC_ROS_WS/src or already mounted by another
#     agent), optional EVIDENCE at /evidence, and per-task build/install/log
#     volumes. Nothing else from the host.
#   - -c/-m (or ISAAC_AGENT_CPUS/ISAAC_AGENT_MEM) cap CPU and memory.
# Never touches an unlabelled container, notably isaac_ros_jazzy_container.
# On macOS (the mini) `up` starts Colima if needed and `down`/`clean` stop it
# when no container is left running. bash 3.2 compatible.
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEXEC="$SELF/dexec.sh"
LABEL=thornbots.agent
LOCK=/tmp/thornbots-agent.lock
DOM_MIN=100
DOM_MAX=199
OS="$(uname -s)"

die() { echo "agent_container.sh: $*" >&2; exit 1; }
say() { echo "agent_container.sh: $*" >&2; }

if [ "$OS" = Darwin ]; then
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    [ -n "${DOCKER_HOST:-}" ] || [ ! -S "$HOME/.colima/default/docker.sock" ] \
        || export DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"
fi

HELD=0
lock() {
    local i=0 pid
    until mkdir "$LOCK" 2>/dev/null; do
        pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then rm -rf "$LOCK"; continue; fi
        i=$((i + 1)); [ "$i" -le 1800 ] || die "lock $LOCK held by pid ${pid:-?} for 30 min"
        sleep 1
    done
    echo $$ >"$LOCK/pid"; HELD=1
}
unlock() { [ "$HELD" -eq 1 ] && rm -rf "$LOCK"; HELD=0; return 0; }

colima_up() {
    [ "$OS" = Darwin ] || return 0
    command -v colima >/dev/null || die "colima not found"
    colima status >/dev/null 2>&1 || { say "starting colima"; colima start >&2 || die "colima start failed"; }
    [ -z "${DOCKER_HOST:-}" ] && [ -S "$HOME/.colima/default/docker.sock" ] \
        && export DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"
    return 0
}

# Caller holds the lock, so a concurrent `up` cannot land between check and stop.
colima_stop_if_idle() {
    [ "$OS" = Darwin ] || return 0
    colima status >/dev/null 2>&1 || return 0
    if [ -n "$(docker ps -q 2>/dev/null)" ]; then
        say "colima left running: other containers are up"
    else
        say "no containers running: stopping colima"; colima stop >&2
    fi
}

valid_task() { printf '%s' "$1" | grep -Eq '^[a-z0-9][a-z0-9-]{0,39}$'; }
cname() { echo "isaac-agent-$1"; }
label_of() { docker inspect -f "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null; }

# Domains/partitions taken by any labelled container (running or not) plus the
# ROS_DOMAIN_ID env of every running one.
taken() { # field: domain|partition
    local c
    docker ps -aq --filter "label=$LABEL" | while read -r c; do label_of "$c" "thornbots.$1"; done
    if [ "$1" = domain ]; then
        docker ps -q | while read -r c; do
            docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" | sed -n 's/^ROS_DOMAIN_ID=//p'
        done
    fi
}

pick_image() {
    [ -n "${1:-}" ] && { echo "$1"; return; }
    [ "$OS" = Darwin ] && { echo thornbots-mac; return; }
    local img
    img="$(docker inspect -f '{{.Config.Image}}' isaac_ros_jazzy_container 2>/dev/null || true)"
    [ -n "$img" ] || img="$(docker images --format '{{.CreatedAt}}|{{.Repository}}:{{.Tag}}' \
        | grep 'thornbots.*amd64' | sort -r | head -1 | cut -d'|' -f2)"
    [ -n "$img" ] || die "no thornbots image found; pass -i IMAGE"
    echo "$img"
}

remove_task() { # task; removes container + volumes, only if labelled for this task
    local task="$1" c v
    c="$(cname "$task")"
    if docker inspect "$c" >/dev/null 2>&1; then
        [ "$(label_of "$c" "$LABEL")" = "$task" ] || die "$c is not a labelled agent container; refusing"
        docker rm -f -v "$c" >/dev/null
    fi
    for v in build install log; do
        [ "$(docker volume inspect -f "{{index .Labels \"$LABEL\"}}" "$c-$v" 2>/dev/null)" = "$task" ] \
            && docker volume rm -f "$c-$v" >/dev/null
    done
    return 0
}

cmd_down() {
    local task="${1:-}"; valid_task "$task" || die "usage: down <task>"
    lock; remove_task "$task"; say "removed $(cname "$task")"; colima_stop_if_idle; unlock
}

cmd_up() {
    local task="${1:-}"; valid_task "$task" || die "task must match [a-z0-9][a-z0-9-]{0,39}"
    shift
    local src="" ev="" cpus="${ISAAC_AGENT_CPUS:-}" mem="${ISAAC_AGENT_MEM:-}" image="" dom="" opt
    OPTIND=1
    while getopts "w:e:c:m:i:d:" opt; do
        case "$opt" in
            w) src="$OPTARG" ;; e) ev="$OPTARG" ;; c) cpus="$OPTARG" ;; m) mem="$OPTARG" ;;
            i) image="$OPTARG" ;; d) dom="$OPTARG" ;; *) die "bad option" ;;
        esac
    done
    src="$(cd "${src:-$SELF/../..}" && pwd -P)" || die "source dir missing"
    [ -d "$src/isaac_ros_common" ] || die "$src is not a workspace src/ checkout"
    local shared="${ISAAC_ROS_WS:-$HOME/workspaces/isaac_ros-jazzy}/src"
    [ -d "$shared" ] && [ "$src" = "$(cd "$shared" && pwd -P)" ] \
        && die "refusing the user's shared workspace $shared: use your own worktree (-w)"
    if [ -n "$ev" ]; then mkdir -p "$ev"; ev="$(cd "$ev" && pwd -P)"; fi
    image="$(pick_image "$image")"

    local c; c="$(cname "$task")"
    lock
    trap 'remove_task "$task"; unlock' INT TERM HUP
    colima_up
    docker inspect "$c" >/dev/null 2>&1 && { unlock; die "$c already exists (task name in use; 'down $task' if it is yours)"; }
    # Same checkout under two agents would share build state and edits.
    local other
    other="$(docker ps -aq --filter "label=$LABEL" | while read -r x; do
        [ "$(label_of "$x" thornbots.src)" = "$src" ] && echo "$x"; done | head -1)"
    [ -z "$other" ] || { unlock; die "$src is already mounted by an agent container ($other)"; }

    local part used d start
    used="$(taken domain)"
    if [ -n "$dom" ]; then
        printf '%s' "$dom" | grep -Eq '^[0-9]+$' && [ "$dom" -ge 2 ] && [ "$dom" -le 232 ] \
            || { unlock; die "domain must be 2-232"; }
        printf '%s\n' "$used" | grep -qx "$dom" && { unlock; die "ROS_DOMAIN_ID $dom is in use by another container"; }
    else
        start=$(( $(printf '%s' "$task" | cksum | cut -d' ' -f1) % (DOM_MAX - DOM_MIN + 1) ))
        for d in $(seq 0 $((DOM_MAX - DOM_MIN))); do
            dom=$(( DOM_MIN + (start + d) % (DOM_MAX - DOM_MIN + 1) ))
            printf '%s\n' "$used" | grep -qx "$dom" || break
            dom=""
        done
        [ -n "$dom" ] || { unlock; die "no free ROS_DOMAIN_ID in $DOM_MIN-$DOM_MAX; run 'clean'"; }
    fi
    part="agent-$task-$dom"
    taken partition | grep -qx "$part" && { unlock; die "GZ_PARTITION $part in use"; }

    local now v; now="$(date +%s)"
    for v in build install log; do
        docker volume create --label "$LABEL=$task" --label "thornbots.created=$now" "$c-$v" >/dev/null
    done
    local args=(run -d --init --name "$c" --shm-size=2g
        --label "$LABEL=$task" --label "thornbots.domain=$dom" --label "thornbots.partition=$part"
        --label "thornbots.src=$src" --label "thornbots.created=$now"
        -e "ROS_DOMAIN_ID=$dom" -e "GZ_PARTITION=$part"
        -e "THORNBOTS_ROS_DOMAIN_ID=$dom" -e "THORNBOTS_GZ_PARTITION=$part"
        -v "$src:/workspaces/isaac_ros-dev/src"
        -v "$c-build:/workspaces/isaac_ros-dev/build"
        -v "$c-install:/workspaces/isaac_ros-dev/install"
        -v "$c-log:/workspaces/isaac_ros-dev/log")
    [ -z "$ev" ] || args+=(-v "$ev:/evidence")
    [ -z "$cpus" ] || args+=(--cpus "$cpus")
    [ -z "$mem" ] || args+=(--memory "$mem")
    if [ "$OS" != Darwin ]; then
        args+=(-e HOST_USER_UID="$(id -u)" -e HOST_USER_GID="$(id -g)"
            -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=all --gpus all
            -v /etc/localtime:/etc/localtime:ro
            --entrypoint /usr/local/bin/scripts/workspace-entrypoint.sh)
    fi
    args+=("$image" sleep infinity)
    if ! docker "${args[@]}" >/dev/null; then
        remove_task "$task"; unlock; die "docker run failed"
    fi

    local user=root i
    [ "$OS" = Darwin ] || user=admin
    for i in $(seq 1 60); do
        docker exec "$c" id -u "$user" >/dev/null 2>&1 && break
        [ "$i" -lt 60 ] || { remove_task "$task"; unlock; die "$c never became ready"; }
        sleep 1
    done
    docker exec -u root "$c" chown "$user:$user" /workspaces/isaac_ros-dev/build \
        /workspaces/isaac_ros-dev/install /workspaces/isaac_ros-dev/log >/dev/null
    trap - INT TERM HUP
    unlock
    print_env "$task"
}

print_env() {
    local task="$1" c; c="$(cname "$task")"
    docker inspect "$c" >/dev/null 2>&1 || die "$c does not exist"
    local dom part; dom="$(label_of "$c" thornbots.domain)"; part="$(label_of "$c" thornbots.partition)"
    echo "container=$c"
    echo "ROS_DOMAIN_ID=$dom"
    echo "GZ_PARTITION=$part"
    echo "MCB_PTY=/tmp/mcb_emulator_pty-$part-$dom"
    echo "src=$(label_of "$c" thornbots.src)"
    echo "export ISAAC_ROS_CONTAINER=$c"
}

RUN_TASK=""
cmd_run() {
    local task="${1:-}"; valid_task "$task" || die "usage: run <task> [opts] -- <cmd...>"
    RUN_TASK="$task"
    shift
    local opts=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do opts+=("$1"); shift; done
    [ "${1:-}" = "--" ] && shift
    [ "$#" -gt 0 ] || die "run: no command"
    trap 'unlock; lock; remove_task "$RUN_TASK" 2>/dev/null; colima_stop_if_idle; unlock' EXIT
    trap 'exit 130' INT TERM HUP
    cmd_up "$task" ${opts[@]+"${opts[@]}"} || exit 1
    ISAAC_ROS_CONTAINER="$(cname "$task")" "$DEXEC" -- "$@"
}

cmd_ls() {
    docker ps -a --filter "label=$LABEL" --format \
        'table {{.Names}}\t{{.Label "thornbots.domain"}}\t{{.Label "thornbots.partition"}}\t{{.Status}}\t{{.CreatedAt}}'
    echo "volumes:"; docker volume ls -q --filter "label=$LABEL"
}

# Removes labelled containers older than HOURS whose only processes are init and
# sleep (plus a ros2 daemon), and labelled volumes older than that that have
# no container.
cmd_clean() {
    local hours=6 dry=0 opt
    OPTIND=1
    while getopts "t:n" opt; do case "$opt" in t) hours="$OPTARG" ;; n) dry=1 ;; *) die "bad option" ;; esac; done
    local now cutoff c task created busy v
    now="$(date +%s)"; cutoff=$((now - hours * 3600))
    lock
    for c in $(docker ps -aq --filter "label=$LABEL"); do
        task="$(label_of "$c" "$LABEL")"; created="$(label_of "$c" thornbots.created)"
        [ "${created:-0}" -lt "$cutoff" ] || continue
        # A container whose process list cannot be read is kept, never removed.
        busy="$(docker top "$c" -eo pid,args 2>/dev/null)" || { say "keep $task: cannot list processes"; continue; }
        busy="$(printf '%s\n' "$busy" | tail -n +2 | grep -v -e 'sleep infinity' -e 'ros2-daemon' || true)"
        if [ -n "$busy" ]; then say "keep $task: processes running"; continue; fi
        if [ "$dry" -eq 1 ]; then say "would remove $(cname "$task")"; else remove_task "$task"; say "removed $(cname "$task")"; fi
    done
    for v in $(docker volume ls -q --filter "label=$LABEL"); do
        task="$(docker volume inspect -f "{{index .Labels \"$LABEL\"}}" "$v")"
        created="$(docker volume inspect -f '{{index .Labels "thornbots.created"}}' "$v")"
        docker inspect "$(cname "$task")" >/dev/null 2>&1 && continue
        [ "${created:-0}" -lt "$cutoff" ] || continue
        if [ "$dry" -eq 1 ]; then say "would remove volume $v"; else docker volume rm -f "$v" >/dev/null; say "removed volume $v"; fi
    done
    [ "$dry" -eq 1 ] || colima_stop_if_idle
    unlock
}

sub="${1:-}"; [ "$#" -gt 0 ] && shift
case "$sub" in
    up) cmd_up "$@" ;;
    run) cmd_run "$@" ;;
    down) cmd_down "$@" ;;
    env) valid_task "${1:-}" || die "usage: env <task>"; print_env "$1" ;;
    ls) cmd_ls ;;
    clean) cmd_clean "$@" ;;
    *) sed -n '2,12p' "${BASH_SOURCE[0]}" >&2; exit 2 ;;
esac
