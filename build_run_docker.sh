#!/bin/bash

## This file does the following
## i. Builds Docker image of ndb-agent & Flask server
## i. Generates event topology file for the Flask server (with given configuration)
## i. Creates docker-compose file (with given configuration)
## i. Runs docker-compose

set -e

function print_usage() {
    cat <<EOF
Usage:
  $0    [-v     --rondb-version]
        [-g     --glibc-version]
        [-m     --num-mgm-nodes]
        [-d     --num-data-nodes]
        [-r     --replication-factor]
        [-my    --num-mysql-nodes]
        [-a     --num-api-nodes]
        [-det   --detached]
EOF
}

if [ -z "$1" ]; then
    print_usage
    exit 0
fi

#######################
#### CLI Arguments ####
#######################

# Defaults
NUM_MYSQL_NODES=0
NUM_API_NODES=0

POSITIONAL=()
while [[ $# -gt 0 ]]; do
    key="$1"

    case $key in
    -v | --rondb-version)
        RONDB_VERSION="$2"
        shift # past argument
        shift # past value
        ;;
    -g | --glibc-version)
        GLIBC_VERSION="$2"
        shift # past argument
        shift # past value
        ;;
    -m | --num-mgm-nodes)
        NUM_MGM_NODES="$2"
        shift # past argument
        shift # past value
        ;;
    -d | --num-data-nodes)
        NUM_DATA_NODES="$2"
        shift # past argument
        shift # past value
        ;;
    -r | --replication-factor)
        REPLICATION_FACTOR="$2"
        shift # past argument
        shift # past value
        ;;
    -my | --num-mysql-nodes)
        NUM_MYSQL_NODES="$2"
        shift # past argument
        shift # past value
        ;;
    -a | --num-api-nodes)
        NUM_API_NODES="$2"
        shift # past argument
        shift # past value
        ;;

    -det | --detached)
        DOCKER_COMPOSE_DETACHED="-d"
        shift # past argument
        ;;

    *)                     # unknown option
        POSITIONAL+=("$1") # save it in an array for later
        shift              # past argument
        ;;
    esac
done

set -- "${POSITIONAL[@]}" # restore positional parameters

echo "RonDB version                             = ${RONDB_VERSION}"
echo "Glibc version                             = ${GLIBC_VERSION}"
echo "Number of management nodes                = ${NUM_MGM_NODES}"
echo "Number of data nodes                      = ${NUM_DATA_NODES}"
echo "Replication factor                        = ${REPLICATION_FACTOR}"
echo "Number of mysql nodes                     = ${NUM_MYSQL_NODES}"
echo "Number of api nodes                       = ${NUM_API_NODES}"
echo "Running docker-compose in detached mode   = ${DOCKER_COMPOSE_DETACHED}"

if [[ -n $1 ]]; then
    echo "Last line of file specified as non-opt/last argument:"
    tail -1 "$1"
fi

# https://stackoverflow.com/a/246128/9068781
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

AUTOGENERATED_FILES_DIR="$SCRIPT_DIR/autogenerated_files"
mkdir -p $AUTOGENERATED_FILES_DIR

FILE_SUFFIX="v${RONDB_VERSION}_m${NUM_MGM_NODES}_d${NUM_DATA_NODES}_r${REPLICATION_FACTOR}_my${NUM_MYSQL_NODES}_api${NUM_API_NODES}"
DOCKER_COMPOSE_FILEPATH="$AUTOGENERATED_FILES_DIR/docker_compose_$FILE_SUFFIX.yml"
CONFIG_INI_FILEPATH="$AUTOGENERATED_FILES_DIR/config_$FILE_SUFFIX.ini"
MY_CNF_FILEPATH="$AUTOGENERATED_FILES_DIR/my_$FILE_SUFFIX.cnf"

#######################
#######################
#######################

echo "Building RonDB Docker image for local platform"

RONDB_IMAGE_NAME="rondb:$RONDB_VERSION"
docker buildx build . \
    --tag $RONDB_IMAGE_NAME \
    --build-arg RONDB_VERSION=$RONDB_VERSION \
    --build-arg GLIBC_VERSION=$GLIBC_VERSION

#######################
#######################
#######################

echo "Loading templates"

CONFIG_INI_TEMPLATE=$(cat ./resources/config_templates/config.ini)
CONFIG_INI_MGMD_TEMPLATE=$(cat ./resources/config_templates/config_mgmd.ini)
CONFIG_INI_NDBD_TEMPLATE=$(cat ./resources/config_templates/config_ndbd.ini)
CONFIG_INI_MYSQLD_TEMPLATE=$(cat ./resources/config_templates/config_mysqld.ini)
CONFIG_INI_API_TEMPLATE=$(cat ./resources/config_templates/config_api.ini)

MY_CNF_TEMPLATE=$(cat ./resources/config_templates/my.cnf)

# Doing restart on-failure for the agent upgrade; we return a failure there
RONDB_DOCKER_COMPOSE_TEMPLATE="

    <insert-service-name>:
      image: $RONDB_IMAGE_NAME
      container_name: <insert-service-name>
"

VOLUMES_FIELD="
      volumes:"

# Bind config.ini to mgmd containers
BIND_CONFIG_INI_TEMPLATE="
      - type: bind
        source: $CONFIG_INI_FILEPATH
        target: /srv/hops/mysql-cluster/config.ini"

# Bind my.cnf to mgmd containers
BIND_MY_CNF_TEMPLATE="
      - type: bind
        source: $MY_CNF_FILEPATH
        target: /srv/hops/mysql-cluster/my.cnf"

VOLUME_DATA_DIR_TEMPLATE="
      - %s:/srv/hops/mysql-cluster/%s"

COMMAND_TEMPLATE="
      command: [ %s ]"

#######################
#######################
#######################

echo "Filling out templates"

CONFIG_INI=$(printf "$CONFIG_INI_TEMPLATE" "$REPLICATION_FACTOR")
MGM_CONNECTION_STRING=''
VOLUMES=()
BASE_DOCKER_COMPOSE_FILE="version: '3.7'

services:"

for CONTAINER_NUM in $(seq $NUM_MGM_NODES); do
    NODE_ID=$((65 + $(($CONTAINER_NUM - 1)) ))

    template="$RONDB_DOCKER_COMPOSE_TEMPLATE"
    SERVICE_NAME="mgm_$CONTAINER_NUM"
    template=$(echo "$template" | sed "s/<insert-service-name>/$SERVICE_NAME/g")
    command=$(printf "$COMMAND_TEMPLATE" "\"ndb_mgmd\", \"--ndb-nodeid=$NODE_ID\", \"--initial\"")
    template+="$command"
    template+="$VOLUMES_FIELD"
    template+="$BIND_CONFIG_INI_TEMPLATE"
    VOLUME_NAME="vol_$SERVICE_NAME"
    volume=$(printf "$VOLUME_DATA_DIR_TEMPLATE" "$VOLUME_NAME" "mgmd")
    template+="$volume"
    VOLUMES+=("$VOLUME_NAME")

    BASE_DOCKER_COMPOSE_FILE+="$template"

    # NodeId, HostName, PortNumber, NodeActive, ArbitrationRank
    SLOT=$(printf "$CONFIG_INI_MGMD_TEMPLATE" "$NODE_ID" "$SERVICE_NAME" "1186" "1" "0")
    CONFIG_INI=$(printf "%s\n\n%s" "$CONFIG_INI" "$SLOT")

    MGM_CONNECTION_STRING+="$SERVICE_NAME:1186,"
done

# We're not bothering with inactive ndbds here
NUM_NODE_GROUPS=$(($NUM_DATA_NODES / $REPLICATION_FACTOR))
for CONTAINER_NUM in $(seq $NUM_DATA_NODES); do
    NODE_ID=$((1 + $(($CONTAINER_NUM - 1)) ))

    template="$RONDB_DOCKER_COMPOSE_TEMPLATE"
    SERVICE_NAME="ndbd_$CONTAINER_NUM"
    template=$(echo "$template" | sed "s/<insert-service-name>/$SERVICE_NAME/g")
    command=$(printf "$COMMAND_TEMPLATE" "\"ndbmtd\", \"--ndb-nodeid=$NODE_ID\", \"--initial\", \"--ndb-connectstring=$MGM_CONNECTION_STRING\"")
    template+="$command"
    template+="$VOLUMES_FIELD"
    VOLUME_NAME="vol_$SERVICE_NAME"
    volume=$(printf "$VOLUME_DATA_DIR_TEMPLATE" "$VOLUME_NAME" "ndbd")
    template+="$volume"
    VOLUMES+=("$VOLUME_NAME")

    BASE_DOCKER_COMPOSE_FILE+="$template"

    NODE_GROUP=$(($CONTAINER_NUM % $NUM_NODE_GROUPS))
    # NodeId, NodeGroup, NodeActive, HostName, ServerPort, FileSystemPath (NodeId)
    SLOT=$(printf "$CONFIG_INI_NDBD_TEMPLATE" "$NODE_ID" "$NODE_GROUP" "1" "$SERVICE_NAME" "11860" "$NODE_ID")
    CONFIG_INI=$(printf "%s\n\n%s" "$CONFIG_INI" "$SLOT")
done

SLOTS_PER_CONTAINER=2  # Cannot scale out a lot on a single machine
for CONTAINER_NUM in $(seq $NUM_MYSQL_NODES); do
    template="$RONDB_DOCKER_COMPOSE_TEMPLATE"
    SERVICE_NAME="mysql_$CONTAINER_NUM"
    template=$(echo "$template" | sed "s/<insert-service-name>/$SERVICE_NAME/g")
    command=$(printf "$COMMAND_TEMPLATE" "\"mysqld\"")
    template+="$command"
    template+="$VOLUMES_FIELD"
    template+="$BIND_MY_CNF_TEMPLATE"
    VOLUME_NAME="vol_$SERVICE_NAME"
    volume=$(printf "$VOLUME_DATA_DIR_TEMPLATE" "$VOLUME_NAME" "mysqld")
    template+="$volume"
    VOLUMES+=("$VOLUME_NAME")

    BASE_DOCKER_COMPOSE_FILE+="$template"
    
    NODE_ID_OFFSET=$(( $(($CONTAINER_NUM - 1)) * $SLOTS_PER_CONTAINER))
    for SLOT_NUM in $(seq $SLOTS_PER_CONTAINER); do
        NODE_ID=$((67 + $NODE_ID_OFFSET + $(($SLOT_NUM - 1)) ))
        # NodeId, NodeActive, ArbitrationRank, HostName
        SLOT=$(printf "$CONFIG_INI_MYSQLD_TEMPLATE" "$NODE_ID" "1" "1" "$SERVICE_NAME")
        CONFIG_INI=$(printf "%s\n\n%s" "$CONFIG_INI" "$SLOT")
    done
done

# Append volumes to end of file
BASE_DOCKER_COMPOSE_FILE+="

volumes:"

for VOLUME in "${VOLUMES[@]}"; do
    BASE_DOCKER_COMPOSE_FILE+="
    $VOLUME:"
done

BASE_DOCKER_COMPOSE_FILE+="
"

#######################
#######################
#######################

echo "Writing data to files"

if [ "$NUM_MYSQL_NODES" -gt 0 ]; then
    echo "Writing my.cnf"
    MY_CNF=$(printf "$MY_CNF_TEMPLATE" "$SLOTS_PER_CONTAINER" "$MGM_CONNECTION_STRING")
    echo "$MY_CNF" >$MY_CNF_FILEPATH
fi

echo "$BASE_DOCKER_COMPOSE_FILE" >$DOCKER_COMPOSE_FILEPATH
echo "$CONFIG_INI" >$CONFIG_INI_FILEPATH

# Remove previous volumes
docker-compose -f $DOCKER_COMPOSE_FILEPATH -p "rondb_$FILE_SUFFIX" down -v
docker-compose -f $DOCKER_COMPOSE_FILEPATH -p "rondb_$FILE_SUFFIX" up $DOCKER_COMPOSE_DETACHED
