#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== Running Full SC26 HeadNode Setup & Post-Configuration ==="
mkdir -p /shared/deploy
cp -r "${SCRIPT_DIR}" /shared/deploy/nersc-sc26 2>/dev/null || true
ln -sfn /shared/deploy /deploy

# Register compute-node-setup.sh in ParallelCluster's native /opt/slurm/etc/scripts/prolog.d/ directory
if [ -d /opt/slurm/etc/scripts/prolog.d ]; then
    ln -sf /shared/deploy/nersc-sc26/setup/compute-node-setup.sh /opt/slurm/etc/scripts/prolog.d/90_sc26_compute_setup.sh
    chmod +x /shared/deploy/nersc-sc26/setup/compute-node-setup.sh
fi

# Enable lightweight squid forward proxy (port 3128) on HeadNode so multi-NIC p4d.24xlarge
# compute nodes (which run with AssignPublicIp: false) can fetch packages and HTTPS URLs
dnf install -y -q squid >/dev/null 2>&1 || true
systemctl enable --now squid >/dev/null 2>&1 || true

bash "${SCRIPT_DIR}/setup/create-users.sh"
bash "${SCRIPT_DIR}/setup/install-software.sh"
bash "${SCRIPT_DIR}/setup/configure-ondemand-cluster.sh"
bash "${SCRIPT_DIR}/post/configure-user-ssh.sh"
bash "${SCRIPT_DIR}/post/configure-slurm.sh"
bash "${SCRIPT_DIR}/post/configure-ondemand-auth.sh"

echo "=== Full SC26 HeadNode Setup & Post-Configuration Complete! ==="
