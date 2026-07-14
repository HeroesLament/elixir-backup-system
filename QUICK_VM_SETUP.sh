#!/bin/bash
# Quick Debian 13 minimal VM setup for EBS testing
# Run this on virt-2.admin.siliconiq.com as root

set -e

VMID=999
VM_NAME="ebs-test-vm"
DISK_SIZE="10G"
DISK_PATH="/var/lib/vz/images/${VMID}"
WORK_DIR="/tmp/ebs-vm-build"

echo "=== EBS Test VM Setup ==="
echo "VMID: $VMID"
echo "Name: $VM_NAME"
echo "Disk: $DISK_SIZE qcow2"
echo ""

# Step 1: Create directories
echo "[1/7] Creating directories..."
mkdir -p "$DISK_PATH"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Step 2: Run debootstrap
echo "[2/7] Running debootstrap (may take 2-3 min)..."
if ! command -v debootstrap &> /dev/null; then
    apt-get update
    apt-get install -y debootstrap
fi

debootstrap --variant=minbase trixie "$WORK_DIR/debian-root"

# Step 3: Configure rootfs
echo "[3/7] Configuring filesystem..."
cat > "$WORK_DIR/debian-root/configure.sh" << 'CONF_EOF'
#!/bin/bash
set -e

# Update packages
apt-get update
apt-get install -y --no-install-recommends \
    linux-image-amd64 \
    grub-pc \
    openssh-server \
    curl \
    ca-certificates

# SSH config
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# Root password (change this!)
echo "root:ebs-backup" | chpasswd

# Hostname
echo "ebs-test-vm" > /etc/hostname

# Fstab
cat > /etc/fstab << 'FSTAB_EOF'
/dev/sda1 / ext4 defaults 0 1
proc /proc proc defaults 0 0
sysfs /sys sysfs defaults 0 0
FSTAB_EOF

echo "Rootfs configured"
CONF_EOF

chmod +x "$WORK_DIR/debian-root/configure.sh"
chroot "$WORK_DIR/debian-root" /configure.sh

# Step 4: Create qcow2 disk
echo "[4/7] Creating qcow2 disk image..."
qemu-img create -f qcow2 "$DISK_PATH/vm-${VMID}-disk-0.qcow2" "$DISK_SIZE"

# Step 5: Format and mount disk
echo "[5/7] Formatting and mounting disk..."
# Use loopback to format the qcow2
LOOP_DEV=$(losetup -f)
losetup "$LOOP_DEV" "$DISK_PATH/vm-${VMID}-disk-0.qcow2"
mkfs.ext4 -F "$LOOP_DEV"
MOUNT_POINT="/mnt/ebs-vm-disk"
mkdir -p "$MOUNT_POINT"
mount "$LOOP_DEV" "$MOUNT_POINT"

# Step 6: Copy rootfs to disk
echo "[6/7] Copying filesystem to disk..."
cp -a "$WORK_DIR/debian-root"/* "$MOUNT_POINT/"

# Install grub to disk
mkdir -p "$MOUNT_POINT/boot/grub"
grub-install --root-directory="$MOUNT_POINT" "$LOOP_DEV" 2>/dev/null || true

# Unmount
sync
umount "$MOUNT_POINT"
losetup -d "$LOOP_DEV"

# Step 7: Create Proxmox VM
echo "[7/7] Creating Proxmox VM (vmid $VMID)..."
qm create "$VMID" \
    --name "$VM_NAME" \
    --memory 512 \
    --cores 1 \
    --sockets 1 \
    --cpu host \
    --net0 "virtio,bridge=vmbr0" \
    --ostype l26 \
    --bios seabios

# Attach disk
qm set "$VMID" --scsi0 "local:$VMID/vm-${VMID}-disk-0.qcow2"

# Enable agent
qm set "$VMID" --agent enabled=1

echo ""
echo "=== VM Created Successfully ==="
echo "VMID: $VMID"
echo "Name: $VM_NAME"
echo "Disk: $DISK_PATH/vm-${VMID}-disk-0.qcow2"
echo ""
echo "Next steps:"
echo "1. Start VM:  qm start $VMID"
echo "2. Get IP:    qm guest cmd $VMID network-get-interfaces"
echo "3. SSH in:    ssh root@<vm-ip>"
echo "4. Password:  ebs-backup"
echo ""
echo "Cleanup:"
echo "  rm -rf $WORK_DIR"
echo "  qm stop $VMID"
echo "  qm destroy $VMID"
echo "  rm -rf $DISK_PATH"
