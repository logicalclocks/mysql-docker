#!/usr/bin/env sh

EXECUTE_SQL=""
DB=
MYSQL_CONF=/srv/hops/mysql-cluster/my.cnf

# Either a 'db' will be passed as an argument, or not:
# Case 1:
# mysql -u root -pPasswd mysql -e "show tables"
# Case 2:
# mysql -u root -pPasswd -e "show databases"
# Case 3 (to log into the shell):
# mysql -u root -pPasswd

if [ $# -gt 1 ]; then
    EXECUTE_SQL="-e"
# Case 1
    if [ "$2" = "-e" ]; then
        DB=$1
        shift # remove 'db'
# Case 2
    fi
    shift # remove '-e'
fi

MYSQL_SOCKET=$(/srv/hops/mysql-cluster/ndb/scripts/get-mysql-socket.sh)
echo "Using socket: $MYSQL_SOCKET"
if [ "$EXECUTE_SQL" = "-e" ]; then
    mysql_command="/srv/hops/mysql/bin/mysql --defaults-file=$MYSQL_CONF -u root --skip-password -S $MYSQL_SOCKET $DB $EXECUTE_SQL '$@'"
    echo "Executing command: $mysql_command"
    eval $mysql_command
else
# Case 3
    mysql_command="/srv/hops/mysql/bin/mysql --defaults-file=$MYSQL_CONF -u root --skip-password -S $MYSQL_SOCKET $DB $@"
    echo "Executing command: $mysql_command"
    eval $mysql_command
fi
exit $?
