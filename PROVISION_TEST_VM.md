# Provision Test VM for EBS Backup Testing

We need a minimal Debian 13 VM to test EBS backups against.

## Requirements

- **OS**: Debian 13 (minimal install)
- **Storage**: 5-10GB disk (qcow2 format for CBT support)
- **Memory**: 512MB (minimal)
- **vCPU**: 1 core
- **Network**: DHCP
- **Disk format**: qcow2 (required for dirty bitmap/CBT support)

---

## Option 1: Debootstrap on virt-2 (Recommended)

This creates a minimal Debian 13 root filesystem using debootstrap, then provisions a VM from it.

### Step 1: SSH to virt-2

```bash
ssh root@virt-2.admin.siliconiq.com
```

### Step 2: Create debootstrap filesystem

```bash
# Create temp directory
mkdir -p /tmp/ebs-test-vm
cd /tmp/ebs-test-vm

# Run debootstrap (creates minimal Debian 13 filesystem)
debootstrap --variant=minbase trixie debian-root

# This downloads minimal packages and creates:
# debian-root/
# ├── bin/
# ├── etc/
# ├── boot/
# ├── root/
# ├── var/
# └── (other std filesystem dirs)
```

### Step 3: Configure rootfs

```bash
# Enter chroot
chroot debian-root

# Set root password
passwd

# Install essentials
apt-get update
apt-get install -y \
  linux-image-amd64 \
  grub-pc \
  openssh-server \
  curl \
  vim

# Configure SSH
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

# Exit chroot
exit
```

### Step 4: Create disk image

```bash
# Create qcow2 disk (10GB, required for CBT)
qemu-img create -f qcow2 /var/lib/vz/images/999/vm-999-disk-0.qcow2 10G

# Format filesystem onto disk
sudo mkfs.ext4 -F /var/lib/vz/images/999/vm-999-disk-0.qcow2

# Mount and copy filesystem
mkdir /mnt/disk
sudo mount -o loop /var/lib/vz/images/999/vm-999-disk-0.qcow2 /mnt/disk
sudo cp -a debian-root/* /mnt/disk/
sudo umount /mnt/disk

# Cleanup
rm -rf debian-root
```

### Step 5: Create Proxmox VM

```bash
# Create VM (vmid 999)
qm create 999 \
  --name ebs-test-vm \
  --memory 512 \
  --cores 1 \
  --sockets 1 \
  --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-pci

# Attach disk
qm set 999 --scsi0 local-lvm:vm-999-disk-0

# Enable QEMU Guest Agent
qm set 999 --agent enabled=1

# Enable qcow2 bitmap for CBT
qm set 999 --format qcow2

# Start VM
qm start 999

# Get IP
qm guest cmd 999 network-get-interfaces | jq .
```

---

## Option 2: Proxmox ISO Install (Easier)

If debootstrap is too manual, use Debian 13 netinst ISO:

```bash
# Download Debian 13 netinst
wget https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13-netinst-amd64.iso \
  -O /var/lib/vz/template/iso/debian-13-netinst.iso

# Create VM
qm create 999 \
  --name ebs-test-vm \
  --memory 512 \
  --cores 1 \
  --ide2 local:iso/debian-13-netinst.iso,media=cdrom \
  --net0 virtio,bridge=vmbr0

# Add disk
qm set 999 --scsi0 local-lvm:10

# Start and install via console
qm start 999
qm terminal 999
# Follow Debian installer (very fast on minimal)
```

---

## Option 3: Clone from Golden Image

If you already have your vmid105 golden template:

```bash
# Clone vmid105 to vmid999
qm clone 105 999 --name ebs-test-vm

# Resize disk to 5GB (or smaller)
qm resize 999 scsi0 5G

# Modify networking (change MAC to avoid conflicts)
qm set 999 --net0 virtio,bridge=vmbr0,macaddr=52:54:00:12:34:56

# Boot and test
qm start 999
```

---

## Verify VM Setup

Once VM is running:

```bash
# Get VM IP
qm guest cmd 999 network-get-interfaces

# SSH in and test
ssh root@{vm-ip}

# Verify disk is qcow2
file /var/lib/vz/images/999/vm-999-disk-0.qcow2
# Should show: "QEMU QCOW2 Image (v3), 10737418240 bytes"

# Verify CBT support
virsh dumpxml 999 | grep -i bitmap
# If empty, may not have CBT enabled (depends on QEMU/storage backend)
```

---

## Test EBS Backup Against This VM

Once VM is provisioned and running:

### 1. Verify disk path is accessible from EBS MacBook

```bash
# On virt-2
ls -lh /var/lib/vz/images/999/vm-999-disk-0.qcow2

# Should show: -rw-r--r-- 1 root root 10G Jul 14 12:00 /var/lib/vz/images/999/vm-999-disk-0.qcow2
```

### 2. Test NBD read (manual)

```bash
# Start NBD server
qemu-nbd -f qcow2 /var/lib/vz/images/999/vm-999-disk-0.qcow2 --listen=127.0.0.1 --port=10809 &

# Test read
nbd-client -l 127.0.0.1:10809

# Stop
pkill qemu-nbd
```

### 3. Test EBS backup

```elixir
# In Elixir REPL
iex> EBS.Proxmox.VE.from_config() |> EBS.Proxmox.VE.authenticate()
{:ok, client}

iex> EBS.Proxmox.VE.list_vms(client, "virt-2")
[..., %{"vmid" => 999, "name" => "ebs-test-vm", ...}, ...]

iex> EBS.NBD.DistributedNode.read_blocks("virt-2", 999, "0", 0, 65536)
{:ok, [%{sha256: "...", offset: 0, size: 65536, data: <<...>>}]}
```

---

## Cleanup

When done testing:

```bash
# Stop VM
qm stop 999

# Delete VM and disk
qm destroy 999
rm /var/lib/vz/images/999/vm-999-disk-0.qcow2
```

---

## VM Specs Summary

| Aspect | Value |
|--------|-------|
| VMID | 999 |
| Name | ebs-test-vm |
| OS | Debian 13 (minimal) |
| vCPU | 1 |
| RAM | 512MB |
| Disk | 5-10GB qcow2 |
| Network | DHCP (vmbr0) |
| CBT | Enabled (qcow2 only) |

