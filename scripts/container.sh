# container.sh: sourced by dexec.sh, kill_launch.sh and smoke.sh. Sets
# CONTAINER and CONTAINER_USER; never starts anything.
# CONTAINER: $ISAAC_ROS_CONTAINER, else docker.run.container_name from
# ../.isaac-ros-cli/config.yaml, else the CLI's default
# isaac_ros_dev_container. The Mac container takes the same name.
# CONTAINER_USER: admin in the Isaac ROS image, root in Dockerfile.mac,
# which has no admin user.

_CONFIG="$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../.isaac-ros-cli/config.yaml"
CONTAINER="${ISAAC_ROS_CONTAINER:-$(sed -n "s/^ *container_name: *['\"]\{0,1\}\([^'\" #]*\).*/\1/p" "$_CONFIG" 2>/dev/null || true)}"
CONTAINER="${CONTAINER:-isaac_ros_dev_container}"

container_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]
}

CONTAINER_USER=admin
if container_running "$CONTAINER" && ! docker exec "$CONTAINER" id -u admin >/dev/null 2>&1; then
    CONTAINER_USER=root
fi
