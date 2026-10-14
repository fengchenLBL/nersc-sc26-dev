#!/usr/bin/env bash
set -euo pipefail

echo "=== Installing Open OnDemand & Workshop Software on AWS ParallelCluster HeadNode ==="

# 1. Ensure Slurm binaries from /opt/slurm/bin are globally accessible in /usr/local/bin
if [ -d /opt/slurm/bin ]; then
    for bin in /opt/slurm/bin/*; do
        ln -sf "$bin" "/usr/local/bin/$(basename "$bin")"
    done
fi

# 2. Enable RHEL 8 / Rocky 8 repositories & modules for Open OnDemand 4.0
dnf install -y epel-release || true
dnf config-manager --set-enabled powertools 2>/dev/null || dnf config-manager --set-enabled crb 2>/dev/null || true

dnf module reset nodejs ruby -y || true
dnf module enable nodejs:20 ruby:3.3 -y
dnf module install nodejs:20 ruby:3.3 -y

# 3. Install Open OnDemand release repo, MariaDB (for Slurm Federation slurmdbd), & packages
dnf install -y https://yum.osc.edu/ondemand/latest/ondemand-release-web-latest-1-6.noarch.rpm
dnf install -y ondemand httpd-tools mariadb-server git vim tmux htop nmap-ncat python3.11 python3.11-devel

echo "Open OnDemand & MariaDB software installed!"

# 4. Install shared JupyterLab + PyTorch environment on /opt/slurm/deploy
#    (/opt/slurm is on the HeadNode's fast local GP3 NVMe SSD AND is NFS-exported to all ComputeNodes!)
echo "=== Installing Shared JupyterLab & PyTorch Environment on /opt/slurm/deploy ==="
mkdir -p /opt/slurm/deploy/jupyter /shared/deploy
ln -sfn /opt/slurm/deploy /deploy
ln -sfn /opt/slurm/deploy/jupyter /shared/deploy/jupyter

if [ ! -x /deploy/jupyter/venv/bin/jupyter ]; then
    python3.11 -m venv /opt/slurm/deploy/jupyter/venv
    /opt/slurm/deploy/jupyter/venv/bin/pip install --upgrade pip
    /opt/slurm/deploy/jupyter/venv/bin/pip install jupyterlab notebook ipykernel numpy scipy matplotlib pandas scikit-learn seaborn torch
fi

# 5. Install Open OnDemand Jupyter Interactive App (bc_osc_jupyter)
dnf install -y ondemand-bc_osc_jupyter || true

# 6. Enable Apache httpd for Open OnDemand (close descriptors so SSH sessions never hang)
/opt/ood/ood-portal-generator/sbin/update_ood_portal
systemctl enable httpd </dev/null >/dev/null 2>&1
systemctl start httpd </dev/null >/dev/null 2>&1

echo "=== Open OnDemand & Software Installation Complete! ==="
