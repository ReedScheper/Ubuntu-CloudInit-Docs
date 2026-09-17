#! /bin/bash

set -xe

VMID="${VMID:-8006}"
STORAGE="${STORAGE:-local-zfs}"
DISK_SIZE="${DISK_SIZE:-16G}"

IMG="debian-13-generic-amd64.qcow2"
BASE_URL="https://cloud.debian.org/images/cloud/trixie/latest"
EXPECTED_SHA=$(wget -qO- "$BASE_URL/SHA512SUMS" | awk '/'$IMG'/{print $1}')

download() {
    wget -q "$BASE_URL/$IMG"
}

verify() {
    sha512sum "$IMG" | awk '{print $1}'
}

[ ! -f "$IMG" ] && download

ACTUAL_SHA=$(verify)

if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
    rm -f "$IMG"
    download
    ACTUAL_SHA=$(verify)
    [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ] && exit 1
fi

rm -f debian-13-generic-amd64-resized.qcow2
cp debian-13-generic-amd64.qcow2 debian-13-generic-amd64-resized.qcow2
qemu-img resize debian-13-generic-amd64-resized.qcow2 "$DISK_SIZE"

# Resources follow the +nvidia profile, not the +docker one: the DKMS build of
# the NVIDIA kernel module will crawl (or OOM) on 1 vCPU / 1024 MB.
sudo qm destroy $VMID || true
sudo qm create $VMID --name "debian-13-template-docker-nvidia" --ostype l26 \
    --memory 4096 --balloon 0 \
    --agent 1 \
    --bios ovmf --machine q35 --efidisk0 $STORAGE:0,pre-enrolled-keys=0 \
    --cpu x86-64-v2-AES --cores 4 --numa 1 \
    --vga serial0 --serial0 socket  \
    --net0 virtio,bridge=vmbr0,mtu=1
sudo qm importdisk $VMID debian-13-generic-amd64-resized.qcow2 $STORAGE
sudo qm set $VMID --scsihw virtio-scsi-pci --scsi0 $STORAGE:vm-$VMID-disk-1,discard=on,ssd=1
sudo qm set $VMID --boot order=scsi0
sudo qm set $VMID --scsi1 $STORAGE:cloudinit

if [ ! -d "/var/lib/vz/snippets" ]; then
    mkdir -p "/var/lib/vz/snippets"
fi

# NOTE: heredoc delimiter is quoted ('EOF') so the host shell performs no
# expansion on the cloud-config below. The `main$` in the sed line survives by
# luck in an unquoted heredoc; quoting removes that landmine for future edits.
cat << 'EOF' | sudo tee /var/lib/vz/snippets/debian-13-docker-nvidia.yaml
#cloud-config
runcmd:
    # --- base: enable contrib/non-free (needed by nvidia-driver + firmware) ---
    - "sed -i 's/^Components: main$/Components: main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources"
    - apt-get update
    # linux-headers-amd64 must land BEFORE nvidia-driver; the driver package
    # does not reliably pull it in and the DKMS build will fail without it.
    - apt-get install -y ca-certificates curl gnupg qemu-guest-agent linux-headers-amd64
    - install -m 0755 -d /etc/apt/keyrings

    # --- repo: Docker CE ---
    - curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    - chmod a+r /etc/apt/keyrings/docker.gpg
    - echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian trixie stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    # --- repo: NVIDIA container toolkit ---
    - curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    - chmod a+r /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    - curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    - apt-get update

    # --- Docker engine first: nvidia-ctk needs a daemon to configure ---
    - apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # --- NVIDIA driver. DEBIAN_FRONTEND stops kbd/nvidia-driver from blocking
    #     on ncurses prompts during an unattended first boot. ---
    - DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-driver firmware-misc-nonfree nvidia-smi

    # --- nvidia-ctk: shipped by nvidia-container-toolkit, NOT by
    #     nvidia-container-runtime (that package is only the OCI shim). ---
    - DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-container-toolkit nvidia-container-runtime
    - nvidia-ctk --version

    # --- wire the runtime into /etc/docker/daemon.json ---
    # Append --set-as-default if you want every container to get the NVIDIA
    # runtime without an explicit "runtime: nvidia" in compose.
    - nvidia-ctk runtime configure --runtime=docker
    - systemctl enable docker
    - systemctl restart docker

    # --- CDI spec. Enumerates real devices, so it only succeeds if a GPU is
    #     already passed through to THIS clone. Guarded so a GPU-less clone
    #     does not abort the rest of runcmd (cloud-init runs it under sh -e). ---
    - nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml || true

    - reboot
# Taken from https://forum.proxmox.com/threads/combining-custom-cloud-init-with-auto-generated.59008/page-3#post-428772
EOF

echo "timezone: "$(cat /etc/timezone) | sudo tee -a /var/lib/vz/snippets/debian-13-docker-nvidia.yaml
# echo "locale: "$LANG | sudo tee -a /var/lib/vz/snippets/debian-13.yaml
# As of 2026-02-27 CloudInit is unable to set the locale on Debian 13
# See https://github.com/canonical/cloud-init/pull/6472
# As of 2026-06-07 Setting the locale via the above no longer works

sudo qm set $VMID --cicustom "vendor=local:snippets/debian-13-docker-nvidia.yaml"
sudo qm set $VMID --tags debian-template,debian-13,cloudinit,docker,nvidia
sudo qm set $VMID --ciuser $USER
sudo qm set $VMID --sshkeys ~/.ssh/authorized_keys
sudo qm set $VMID --ipconfig0 ip=dhcp,ip6=dhcp
sudo qm template $VMID

# ---------------------------------------------------------------------------
# Post-clone: the template itself has no GPU. Attach one to the clone BEFORE
# its first boot so the driver install and CDI generation see the device:
#
#   qm clone 8006 120 --name gpu-docker-host --full
#   qm set 120 --hostpci0 0000:01:00,pcie=1
#   qm set 120 --cpu host          # once passthrough has ruled out migration
#   qm start 120
#
# Verify on the clone after it settles (the driver build takes a few minutes):
#   nvidia-smi
#   docker info | grep -i runtime
#   docker run --rm --gpus all nvidia/cuda:12.6.2-base-ubuntu24.04 nvidia-smi
#
# If runcmd died partway, the trail is in:
#   /var/log/cloud-init-output.log
#   journalctl -u cloud-final
# ---------------------------------------------------------------------------
