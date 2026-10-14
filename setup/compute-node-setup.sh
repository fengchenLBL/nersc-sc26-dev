#!/usr/bin/env bash
set -euo pipefail

echo "=== Running SC26 Compute Node Setup (OnNodeConfigured / Prolog) ==="

# 1. Symlink /deploy -> /opt/slurm/deploy (or /shared/deploy) and /share -> /shared so paths work identically on compute nodes
if [ -d /opt/slurm/deploy ] && [ ! -e /deploy ]; then
    ln -sfn /opt/slurm/deploy /deploy
elif [ -d /shared/deploy ] && [ ! -e /deploy ]; then
    ln -sfn /shared/deploy /deploy
fi
ln -sfn /shared /share

cat <<'EOF' > /etc/profile.d/sc26-scratch.sh
# Automatically set per-user isolated $SCRATCH space on shared EFS
if [ -n "${USER:-}" ] && [ -d "/share/users/${USER}" ]; then
    export SCRATCH="/share/users/${USER}"
elif [ -n "${USER:-}" ] && [ -d "/shared/users/${USER}" ]; then
    export SCRATCH="/shared/users/${USER}"
fi
EOF
chmod 644 /etc/profile.d/sc26-scratch.sh

# 2. Ensure Slurm binaries are in /usr/local/bin
if [ -d /opt/slurm/bin ]; then
    for bin in /opt/slurm/bin/*; do
        ln -sf "$bin" "/usr/local/bin/$(basename "$bin")"
    done
fi

# 3. On federated spoke compute nodes (e.g., sc26-east in us-east-2a), mount /federated_home from sc26-west HeadNode
if [ -f /shared/etc/west_headnode_ip ]; then
    WEST_PRIV_IP=$(cat /shared/etc/west_headnode_ip)
    mkdir -p /federated_home
    if ! mountpoint -q /federated_home; then
        mount -t nfs4 -o rw,nfsvers=4.1 "${WEST_PRIV_IP}:/home" /federated_home || true
    fi
fi

# 4. Synchronize workshop users (user1..user100) with identical UIDs/GIDs from /shared/etc/users.list
USERS_LIST="/shared/etc/users.list"
if [ -f "${USERS_LIST}" ]; then
    while IFS=: read -r USERNAME USER_UID PASS; do
        [ -z "${USERNAME}" ] && continue
        if ! id "${USERNAME}" &>/dev/null; then
            groupadd -g "${USER_UID}" "${USERNAME}" 2>/dev/null || true
            # Do not recreate /home/userX since /home is already NFS-mounted from HeadNode
            useradd -M -u "${USER_UID}" -g "${USER_UID}" -d "/home/${USERNAME}" -s /bin/bash "${USERNAME}" 2>/dev/null || true
            echo "${USERNAME}:${PASS}" | chpasswd || true
        fi
    done < "${USERS_LIST}"
    echo "Synchronized workshop users from ${USERS_LIST}"
fi

# 5. Install nmap-ncat (required by Open OnDemand wait_until_port_used) AND python3.11 (required by /deploy/jupyter/venv)
if ! command -v nc &>/dev/null || ! command -v python3.11 &>/dev/null; then
    dnf install -y nmap-ncat python3.11 >/dev/null 2>&1 || yum install -y nmap-ncat python3.11 >/dev/null 2>&1 || true
fi

# 6. Enable & start nvidia-fabricmanager on NVSwitch multi-GPU nodes (e.g., p4d.24xlarge 8x A100)
if systemctl list-unit-files | grep -q nvidia-fabricmanager; then
    systemctl enable nvidia-fabricmanager </dev/null >/dev/null 2>&1 || true
    systemctl start nvidia-fabricmanager </dev/null >/dev/null 2>&1 || true
fi

echo "=== SC26 Compute Node Setup Complete ==="
