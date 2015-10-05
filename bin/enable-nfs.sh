#!/bin/bash -ex

readonly DOCKER_MACHINE="docker-machine"
readonly EXPORTS_FILE="/etc/exports"
readonly HOST_DIR="/Users"
readonly BEGIN_TAG="# ENABLE-NFS-BEGIN"
readonly END_TAG="# ENABLE-NFS-END"
readonly NFS_OPTIONS="async,noatime,actimeo=1,nolock,vers=3,udp"

function usage
{
    echo
    echo "Usage: enable-nfs.sh [options]"
    echo "    -h, --docker-host docker_host"
    echo
}

function exit_error {
    echo $1
    exit 1
}

function executable_installed {
    local executable=$1
    command -v $executable >/dev/null 2>&1 || exit_error "ERROR: $executable has not been installed."
}

function docker_host_exists {
    local docker_host=$1
    local output=`$DOCKER_MACHINE ls | grep $docker_host | awk '{ print $1 }'`

    [ $output = $docker_host ] || exit_error "ERROR: docker host $docker_host does not exist."
}

function remove_nfs_export {
    local docker_host=$1

    local begin_tag="$BEGIN_TAG: $docker_host"
    local end_tag="$END_TAG: $docker_host"

    sudo sed -i -e "/$begin_tag/,/$end_tag/d" $EXPORTS_FILE
}

function stop_docker_machine {
    local docker_host=$1

    $DOCKER_MACHINE stop $docker_host

    unset DOCKER_HOST
    unset DOCKER_CERT_PATH
    unset DOCKER_TLS_VERIFY

    remove_nfs_export $docker_host
}

# Ensure the NFS exports file contains a valid export line
# $1 : exported dir (ex: "/Users/foo")
# $2 : ip address (ex: "172.16.31.197")
function replace_nfs_export {
    local docker_host=$1
    local shared_dir=$2

    local ip=`$DOCKER_MACHINE ip $docker_host`
    local map_to="`id -u`:`id -g`"

    local begin_tag="$BEGIN_TAG: $docker_host"
    local end_tag="$END_TAG: $docker_host"

    sudo bash -c "cat << EOF >> $EXPORTS_FILE
$begin_tag
\"$shared_dir\" $ip -alldirs -mapall=$map_to
$end_tag
EOF"
}

# Copy /etc/localtime from the mac to the Docker host
# See https://github.com/boot2docker/boot2docker/issues/476
function copy_localtime {
    local docker_host=$1

    cat /etc/localtime | $DOCKER_MACHINE ssh $docker_host "sudo /bin/sh -c 'cat > /etc/localtime'"
}

function mount_nfs_volume {
    local docker_host=$1

    local shared_dir=$HOST_DIR/`whoami`
    replace_nfs_export $docker_host $shared_dir

    local host_ip=`$DOCKER_MACHINE ip $docker_host | cut -d'.' -f1-3`.1
    local wait_time=1

    sudo nfsd update

    $DOCKER_MACHINE ssh $docker_host "sudo umount $HOST_DIR 2> /dev/null"

    $DOCKER_MACHINE ssh $docker_host "sudo mkdir -p $shared_dir"
    $DOCKER_MACHINE ssh $docker_host "sudo /usr/local/etc/init.d/nfs-client start"

    until $DOCKER_MACHINE ssh $docker_host "sudo mount $host_ip:$shared_dir $shared_dir -o $NFS_OPTIONS" > /dev/null || [ $wait_time -eq 4 ]
    do
        sleep $(( wait_time++ ))
    done
}

function wait_for_docker_pid {
    local docker_host=$1

    local wait_time=1

    until $DOCKER_MACHINE ssh $docker_host "[ -e /var/run/docker.pid ]" > /dev/null || [ $wait_time -eq 4 ]
    do
        sleep $(( wait_time++ ))
    done
}

function update_env {
    local docker_host=$1

    eval $($DOCKER_MACHINE env $docker_host)
}

function start_docker_machine {
    local docker_host=$1
    local export=$2

    $DOCKER_MACHINE start $docker_host

    copy_localtime $docker_host
    mount_nfs_volume $docker_host
    wait_for_docker_pid $docker_host
    update_env $docker_host
}

function main {
    if [ $# -lt 2 ]; then
        usage
        exit 1
    fi

    while [ "$1" != "" ]; do
        case $1 in
            -h | --docker-host ) shift
                                 local docker_host=$1
                                 ;;
            * )                  echo "unrecognized option: $1"
                                 usage
                                 exit 1
        esac
        shift
    done

    executable_installed nfsd
    executable_installed docker-machine
    docker_host_exists $docker_host

    stop_docker_machine $docker_host
    start_docker_machine $docker_host
}

main "$@"
exit