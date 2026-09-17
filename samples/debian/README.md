
# Scripts for creating Proxmox templates

In this folder are a variety of scripts for setting up Debian VM templates.

## Usage

### Basic Debian 12 "Bookworm" template

```sh
$export VMID=8001 STORAGE=local-zfs
$curl -fsSL https://github.com/ReedScheper/Ubuntu-CloudInit-Docs/raw/refs/heads/main/samples/debian/debian-12-cloudinit.sh | bash
```

### Debian 12 "Bookworm" template with Docker auto-installed

```sh
$export VMID=8002 STORAGE=local-zfs
$curl -fsSL https://github.com/ReedScheper/Ubuntu-CloudInit-Docs/raw/refs/heads/main/samples/debian/debian-12-cloudinit+docker.sh | bash
```

### Basic Debian 13 "Trixie" template

```sh
$export VMID=8003 STORAGE=local-zfs
$curl -fsSL https://github.com/ReedScheper/Ubuntu-CloudInit-Docs/raw/refs/heads/main/samples/debian/debian-13-cloudinit.sh | bash
```

### Debian 13 "Trixie" template with Docker auto-installed

```sh
$export VMID=8004 STORAGE=local-zfs
$curl -fsSL https://github.com/ReedScheper/Ubuntu-CloudInit-Docs/raw/refs/heads/main/samples/debian/debian-13-cloudinit+docker.sh | bash
```

### Debian 13 "Trixie" template with NVidia driver and container runtime auto-installed

```sh
$export VMID=8005 STORAGE=local-zfs
$curl -fsSL https://github.com/ReedScheper/Ubuntu-CloudInit-Docs/raw/refs/heads/main/samples/debian/debian-13-cloudinit+nvidia.sh | bash
```

Note: Building the nvidia driver takes a couple of minutes.

### Debian 13 "Trixie" template with Docker, the NVidia driver and the NVidia Container Toolkit auto-installed

```sh
$export VMID=8006 STORAGE=local-zfs DISK_SIZE=16G
$curl -fsSL https://github.com/ReedScheper/Ubuntu-CloudInit-Docs/raw/refs/heads/main/samples/debian/debian-13-cloudinit+docker+nvidia.sh | bash
```

This combines the Docker and NVidia templates above and additionally installs
`nvidia-container-toolkit`, then runs `nvidia-ctk runtime configure --runtime=docker`
so the NVidia runtime is registered with the Docker daemon on first boot.

`DISK_SIZE` is optional and defaults to 16G. The other templates use 8G, which
leaves very little headroom once the driver, kernel headers, DKMS build
artifacts, the Docker stack and your container images are all on disk.

The template is built with 4 cores and 4GB of RAM, same as the NVidia template,
because the DKMS build of the kernel module is slow on a single core.

#### Attaching a GPU

The template itself has no GPU. Pass one through to the clone *before* its first
boot, so the driver install and the CDI spec generation both see the device:

```sh
$qm clone 8006 120 --name gpu-docker-host --full
$qm set 120 --hostpci0 0000:01:00,pcie=1
$qm start 120
```

Cloud-init reboots the VM once it's finished, so give it a few minutes before
you check:

```sh
$nvidia-smi
$docker info | grep -i runtime
$docker run --rm --gpus all nvidia/cuda:12.6.2-base-ubuntu24.04 nvidia-smi
```

If something went wrong during first boot, look at `/var/log/cloud-init-output.log`
and `journalctl -u cloud-final` on the clone.
