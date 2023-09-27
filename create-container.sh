#!/bin/bash

if [ -z "$1" ]
  then
    echo "No argument supplied. Please provide the container hostname."
    exit 1
fi

while :
do
    read -sp "Please provide root password: " PASSWORD

    if [ ${#PASSWORD} -ge 8 ]
    then
        break;
    fi

    printf "\nerror: Password should be at least 8 characters long.\n\n" >&2
done

HOSTNAME="$1"
install_docker () {
    pct exec $1 -- bash -c "apt-get remove docker docker.io containerd runc"
    pct exec $1 -- bash -c "apt-get install -y ca-certificates curl gnupg lsb-release"
    pct exec $1 -- bash -c "mkdir -p /etc/apt/keyrings"
    pct exec $1 -- bash -c "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
    pct exec $1 -- bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'
    pct exec $1 -- bash -c "apt-get update"
    pct exec $1 -- bash -c "apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin"
}
TEMPLATE_PATH="local:vztmpl/debian-12-standard_12.0-1_amd64.tar.zst"
NETWORK="name=eth0,bridge=vmbr1,ip=dhcp"
CTID=`pvesh get /cluster/nextid`
MEMORY_SIZE=4096
SWAP_SIZE=4096
DISK="volume=local-zfs:40"
CPU_COUNT=2
CMD="pct create ${CTID} ${TEMPLATE_PATH} -net0 ${NETWORK} -onboot 1 -hostname ${HOSTNAME} --password ${PASSWORD} -cores ${CPU_COUNT} -memory=${MEMORY_SIZE} -swap=${SWAP_SIZE} -rootfs ${DISK} --features nesting=1"
echo "Running '${CMD}'..."
$CMD
pct start $CTID
pct exec $CTID -- bash -c 'sed -in "s/#PermitRootLogin prohibit-password/PermitRootLogin yes/" /etc/ssh/sshd_config'
pct exec $CTID -- bash -c 'service sshd restart'
pct exec $CTID -- bash -c "apt-get update && apt-get dist-upgrade -y"
if [ ! -z "$2" ]; then
    case $2 in

      docker)
        install_docker $CTID
      ;;

      php)
        echo -n "Work in progress. Not implemented yet."
      ;;

      *)
        echo -n "unknown"
      ;;
    esac
fi
