#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: sudo $0 <username>"
    exit 1
fi

USERNAME="$1"
HTPASSWD_FILE="/etc/httpd/.htpasswd"
USERS_FILE="/shared/etc/users.list"

# 1. Remove from Open OnDemand htpasswd
if [ -f "${HTPASSWD_FILE}" ]; then
    htpasswd -D "${HTPASSWD_FILE}" "${USERNAME}" 2>/dev/null || true
    echo "Removed ${USERNAME} from ${HTPASSWD_FILE}"
fi

# 2. Stop active PUN if running
if [ -x /opt/ood/nginx_stage/sbin/nginx_stage ]; then
    /opt/ood/nginx_stage/sbin/nginx_stage nginx -u "${USERNAME}" -s stop 2>/dev/null || true
fi

# 3. Cancel active Slurm jobs and remove from Slurm accounting
if [ -x /opt/slurm/bin/scancel ]; then
    /opt/slurm/bin/scancel -u "${USERNAME}" 2>/dev/null || true
fi
if [ -x /opt/slurm/bin/sacctmgr ] && /opt/slurm/bin/sacctmgr show cluster -n &>/dev/null; then
    /opt/slurm/bin/sacctmgr remove user where name="${USERNAME}" -i 2>/dev/null || true
fi

# 4. Remove from /shared/etc/users.list and lock Unix account
if [ -f "${USERS_FILE}" ]; then
    grep -v "^${USERNAME}:" "${USERS_FILE}" > "${USERS_FILE}.tmp" || true
    mv "${USERS_FILE}.tmp" "${USERS_FILE}"
fi

if id "${USERNAME}" &>/dev/null; then
    usermod -L -s /sbin/nologin "${USERNAME}" || true
    echo "Locked Unix account ${USERNAME}"
fi

echo "✓ Workshop user '${USERNAME}' decommissioned."
