#!/bin/bash

if [ -z "$1" ]
  then
    echo "No argument supplied. Please provide the container hostname."
    exit 1
fi

HOSTNAME="$1"

while :
do
    read -p "Please provide a username: " USERNAME

    if [ ${#USERNAME} -ge 2 ]
    then
        break;
    fi

    printf "\nerror: Username should be at least 2 characters long.\n\n" >&2
done

while :
do
    read -p "Please provide a password: " -s PASSWORD

    if [ ${#PASSWORD} -ge 8 ]
    then
        break;
    fi

    printf "\nerror: Password should be at least 8 characters long.\n\n" >&2
done


if [[ ! -e /root/temp ]]; then
    mkdir /root/temp
elif [[ ! -d /root/temp ]]; then
    echo "/root/temp already exists but is not a directory" 1>&2
    exit 1
fi

cd  /root/temp

wget https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2

apt-get update
apt-get install -y libguestfs-tools

virt-customize --install qemu-guest-agent -a debian-12-generic-amd64.qcow2

virt-edit -a debian-12-generic-amd64.qcow2 /etc/ssh/sshd_config -e 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/'

VMID=`pvesh get /cluster/nextid`

# Create a VM
qm create $VMID --name $HOSTNAME --memory 4096 --net0 virtio,bridge=vmbr1 --bootdisk scsi0 --cores 4 --machine q35 --onboot 1 --cpu host

# Import the disk in qcow2 format (as unused disk)
qm importdisk $VMID debian-12-generic-amd64.qcow2 local-zfs -format qcow2

# Attach the disk to the vm using VirtIO SCSI
qm set $VMID --scsihw virtio-scsi-pci --scsi0 local-zfs:vm-$VMID-disk-0,discard=on,ssd=1

# Important settings
qm set $VMID --scsi1 local-zfs:cloudinit --boot c --bootdisk scsi0

# The initial disk is only 2GB, thus we make it larger
qm resize $VMID scsi0 +98G

#Enable Qemu guest agent in case the guest has it available
qm set $VMID --agent enabled=1,fstrim_cloned_disks=1

# Using a  dhcp server on vmbr1 or use static IP
qm set $VMID --ipconfig0 ip=dhcp
#qm set $VMID --ipconfig0 ip=10.10.10.222/24,gw=10.10.10.1

# user authentication for 'debian' user (optional password)
#qm set $VMID --sshkey ~/.ssh/id_rsa.pub
qm set $VMID --ciuser $USERNAME
qm set $VMID --cipassword $PASSWORD

# check the cloud-init config
qm cloudinit dump $VMID user

# create tempalte and a linked clone
#qm template $VMID
#qm clone $VMID 191 --name debian10-1
qm start $VMID

rm -v debian-12-generic-amd64.qcow2
