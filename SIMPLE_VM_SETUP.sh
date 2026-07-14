#!/bin/bash
# Simplified VM setup - just provision an empty qcow2 disk
# Run as root on virt-2

set -e

VMID=999
VM_NAME="ebs-test-vm"
DISK_SIZE="10G"
DISK_PATH="/var/lib/vz/images/${VMID}"
ISO_PATH="/var/lib/vz/template/iso/debian-13-netinst.iso"

echo "=== EBS Test VM Simple Setup ==="

# Step 1: Create disk directory
echo "[1/3] Creating disk directory..."
mkdir -p "$DISK_PATH"

# Step 2: Create qcow2 disk (empty, will boot from ISO)
echo "[2/3] Creating qcow2 disk..."
qemu-img create -f qcow2 "$DISK_PATH/vm-${VMID}-disk-0.qcow2" "$DISK_SIZE"

# Step 3: Create Proxmox VM
echo "[3/3] Creating Proxmox VM..."
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
echo "✓ VM Created!"
echo ""
echo "Next:"
echo "  1. qm start $VMID"
echo "  2. qm terminal $VMID"
echo "  3. Boot minimal Debian installer or use dd to copy a bootable image"
echo ""
echo "Quick test - create a 1GB file to verify backup can read:"
echo "  1. Boot VM to shell"
echo "  2. dd if=/dev/zero of=/test.img bs=1M count=1000"
echo "  3. sync"
echo "  4. Shutdown"
echo ""
echo "Cleanup:"
echo "  qm destroy $VMID"
echo "  rm -rf $DISK_PATH"
