#!/bin/bash

set -e

# https://stackoverflow.com/a/246128/9068781
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

RAW_MYCNF_FILEPATH=/srv/hops/mysql-cluster/my-raw.cnf
MYCNF_FILEPATH=/srv/hops/mysql-cluster/my.cnf

cp $RAW_MYCNF_FILEPATH $MYCNF_FILEPATH

# Equivalent to replication factor of pod
MYSQLD_NR=$(echo $POD_NAME | grep -o '[0-9]\+$')

echo "[Pre-entrypoint-MySQLd-k8] Running MySQLd nr. $MYSQLD_NR with $CONNECTIONS_PER_MYSQLD connections"

FIRST_NODE_ID=$((67+($MYSQLD_NR*$CONNECTIONS_PER_MYSQLD)))
LAST_NODE_ID=$(($FIRST_NODE_ID+$CONNECTIONS_PER_MYSQLD-1))

NODES_SEQ=$(seq -s, $FIRST_NODE_ID $LAST_NODE_ID)

echo "[Pre-entrypoint-MySQLd-k8] Running Node Ids: $NODES_SEQ"

# Replace the existing line with the new sequence in my.cnf
sed -i "/ndb-cluster-connection-pool-nodeids/c\ndb-cluster-connection-pool-nodeids=$NODES_SEQ" $MYCNF_FILEPATH

exec $SCRIPT_DIR/entrypoint.sh "$@"
