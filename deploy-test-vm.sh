#!/bin/bash
# Deploy and run VM setup on virt-2

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/QUICK_VM_SETUP.sh"
REMOTE_HOST="virt-2.admin.siliconiq.com"
REMOTE_USER="root"

echo "Deploying test VM setup to $REMOTE_HOST..."

# Copy script
scp -o StrictHostKeyChecking=no "$SETUP_SCRIPT" "$REMOTE_USER@$REMOTE_HOST:/root/setup-ebs-vm.sh"

# Run it
echo ""
echo "Running setup on virt-2 (this will take 3-5 minutes)..."
echo "============================================================"
ssh -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_HOST" bash /root/setup-ebs-vm.sh

echo ""
echo "============================================================"
echo "✓ Test VM created!"
echo ""
echo "Next steps:"
echo "  ssh root@virt-2.admin.siliconiq.com"
echo "  qm start 999"
echo "  qm guest cmd 999 network-get-interfaces"
echo "  ssh root@<vm-ip>  # password: ebs-backup"
