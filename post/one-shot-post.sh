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

bash "${SCRIPT_DIR}/setup/create-users.sh"
bash "${SCRIPT_DIR}/setup/install-software.sh"
bash "${SCRIPT_DIR}/setup/configure-ondemand-cluster.sh"
bash "${SCRIPT_DIR}/post/configure-user-ssh.sh"
bash "${SCRIPT_DIR}/post/configure-slurm.sh"
bash "${SCRIPT_DIR}/post/configure-ondemand-auth.sh"

echo "=== Full SC26 HeadNode Setup & Post-Configuration Complete! ==="
