#!/bin/bash

# Initialize variables to store the values of the named arguments
hostname=""
password=""
template=""
extras=""
help=false
pveam update >/dev/null 2>&1
available_output=$(pveam available --section system)

# Function to display usage information
usage() {
  echo "Usage: $0 [--hostname <hostname>] [--password <password>] [--template <template>] [--extras <extras_arg>] [--help]"
  exit 1
}

prompt_for_input() {
  local prompt_text="$1"
  local silent="$2"
  local input

  if [ "$silent" = true ]; then
    read -s -p $'\n'"$prompt_text" input
  else
    read -p $'\n'"$prompt_text" input
  fi

  echo "$input"
}

confirm_password() {
  local entered_password
  local confirmed_password

  while true; do
    entered_password=$(prompt_for_input "Enter password: " true)
    confirmed_password=$(prompt_for_input "Confirm password: " true)

    if [ "${#entered_password}" -ge 8 ] && [ "$entered_password" = "$confirmed_password" ]; then
      echo "$entered_password"
      break
    else
      if [ "${#entered_password}" -lt 8 ]; then
        printf "\nError: Password must be at least 8 characters long. Please try again.\n" >&2
      else
        printf "\nError: Passwords do not match. Please try again.\n" >&2
      fi
    fi
  done
}

install_docker () {
  pct exec $CTID -- bash -c "apt-get purge docker docker.io containerd runc"
  pct exec $CTID -- bash -c "apt-get install -y ca-certificates curl gnupg lsb-release"
  pct exec $CTID -- bash -c "mkdir -p /etc/apt/keyrings"
  pct exec $CTID -- bash -c "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
  pct exec $CTID -- bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'
  pct exec $CTID -- bash -c "apt-get update"
  pct exec $CTID -- bash -c "apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin"
}

create_container () {
  bridge_name=$(grep -E -B 7 "#LAN$" /etc/network/interfaces | awk '/auto/ {print $2}')
  TEMPLATE_PATH="local:vztmpl/$template"
  NETWORK="name=eth0,bridge=$bridge_name,ip=dhcp"
  MEMORY_SIZE=4096
  SWAP_SIZE=4096
  DISK="volume=local-zfs:40"
  CPU_COUNT=4
  CMD="pct create ${CTID} ${TEMPLATE_PATH} -net0 ${NETWORK} -onboot 1 -hostname ${hostname} --password ${password} -cores ${CPU_COUNT} -memory=${MEMORY_SIZE} -swap=${SWAP_SIZE} -rootfs ${DISK} --features nesting=1"
  $CMD
  pct start $CTID
  echo "Info: Waiting for the container to obtain it's IP address."
  sleep 10
  while :
  do
    CTIP=$(pct exec $CTID -- bash -c "ip route | awk '/default via/ {print \$5}' | xargs -I {} ip addr show dev {} | awk '/inet / {print \$2}' | cut -d '/' -f 1" 2>/dev/null)
    ipv4_pattern="^(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"
    if [[ $CTIP =~ $ipv4_pattern ]]; then
      echo "Success: The container obtained the IP ${CTIP}."
      break;
    fi
    sleep 5
  done
  pct exec $CTID -- bash -c 'sed -in "s/#PermitRootLogin prohibit-password/PermitRootLogin yes/" /etc/ssh/sshd_config'
  pct exec $CTID -- bash -c 'service sshd restart'
  pct exec $CTID -- bash -c "apt-get update && apt-get dist-upgrade -y"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)
      hostname="$2"
      shift 2
      ;;
    --password)
      password="$2"
      shift 2
      ;;
    --template)
      template="$2"
      shift 2
      ;;
    --extras)
      if [ -z "$extras" ]; then
        extras="$2"
      else
        break
      fi
      shift 2
      ;;
    --help)
      usage
      ;;
    *)
      if [ -z "$hostname" ]; then
        hostname="$1"
      elif [ -z "$password" ]; then
        password="$1"
      elif [ -z "$template" ]; then
        template="$1"
      elif [ -z "$extras" ]; then
        extras="$1"
      else
        echo "Error: Unexpected argument '$1'"
        usage
      fi
      shift
      ;;
  esac
done

# Check if --help was provided
if [ "$help" = true ]; then
  usage
fi

# Prompt for missing values
if [ -z "$hostname" ]; then
  while true; do
    hostname=$(prompt_for_input "Enter hostname: " false)
    if [ "${#hostname}" -ge 6 ]; then
      break
    fi
    printf "\nError: Hostname must be at least 6 characters long. Please try again.\n" >&2

  done
fi

if [ -z "$password" ]; then
  password=$(confirm_password)
fi

if [ -z "$template" ]; then
  counter=1
  while IFS=$'\t ' read -r category package; do
    echo "$counter. $package"
    ((counter++))
  done <<< "$available_output"
  while :
  do
    read -p "Enter the number of the package you want to download: " choice
    if [[ $choice =~ ^[0-9]+$ && $choice -ge 1 && $choice -lt $counter ]]; then
      template=$(echo "$available_output" | sed -n "${choice}p" | awk '{print $2}')
      break
    fi
    echo "Errot: Invalid choice. Please enter a valid number between 1 and $((counter-1))."
  done
fi

if ! grep -q "$template" <<< "$available_output"; then
    echo "Error: Template '$template' is not available."
    exit 1
fi

CTID=`pvesh get /cluster/nextid`

if ! pveam list local | grep -q $template; then
    pveam download local $template
fi

create_container

pveam list local | tail -n +2 | awk '{print $1}' | while read line; do
  pveam remove $line
done

if [ ! -z "$extras" ]; then
    case $extras in
      docker)
        install_docker
      ;;

      php)
        echo -n "Work in progress. Not implemented yet."
      ;;

      *)
        echo -n "unknown"
      ;;
    esac
fi