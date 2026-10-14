#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: sudo $0 <username> [password]"
    exit 1
fi

USERNAME="$1"
PASSWORD="${2:-nersc_${USERNAME}}"
HTPASSWD_FILE="/etc/httpd/.htpasswd"
USERS_FILE="/shared/etc/users.list"

mkdir -p /shared/etc
touch "${USERS_FILE}"

# Compute next deterministic UID (>= 2101)
MAX_UID=$(awk -F: 'BEGIN {max=2100} $2 > max {max=$2} END {print max}' "${USERS_FILE}")
NEXT_UID=$((MAX_UID + 1))

if ! getent group "${USERNAME}" &>/dev/null; then
    groupadd -g "${NEXT_UID}" "${USERNAME}"
fi

if ! id "${USERNAME}" &>/dev/null; then
    useradd -m -u "${NEXT_UID}" -g "${NEXT_UID}" -s /bin/bash "${USERNAME}"
    echo "Created Unix user ${USERNAME} (UID=${NEXT_UID})"
else
    NEXT_UID=$(id -u "${USERNAME}")
    echo "Unix user ${USERNAME} already exists (UID=${NEXT_UID})"
fi

echo "${USERNAME}:${PASSWORD}" | chpasswd

# Record in /shared/etc/users.list so all compute nodes sync automatically
grep -v "^${USERNAME}:" "${USERS_FILE}" > "${USERS_FILE}.tmp" || true
echo "${USERNAME}:${NEXT_UID}:${PASSWORD}" >> "${USERS_FILE}.tmp"
mv "${USERS_FILE}.tmp" "${USERS_FILE}"
chmod 600 "${USERS_FILE}"

# Configure SSH for inter-node communication
USER_HOME="/home/${USERNAME}"
mkdir -p "${USER_HOME}/.ssh"
if [ ! -f "${USER_HOME}/.ssh/id_rsa" ]; then
    ssh-keygen -t rsa -b 2048 -f "${USER_HOME}/.ssh/id_rsa" -N "" -q
fi
cat "${USER_HOME}/.ssh/id_rsa.pub" > "${USER_HOME}/.ssh/authorized_keys"
cat > "${USER_HOME}/.ssh/config" <<'EOF'
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF

[ -f /etc/skel/example-job.sh ] && cp /etc/skel/example-job.sh "${USER_HOME}/"
[ -f /etc/skel/run_pytorch_test.sh ] && cp /etc/skel/run_pytorch_test.sh "${USER_HOME}/"

chown -R "${NEXT_UID}:${NEXT_UID}" "${USER_HOME}"
chmod 700 "${USER_HOME}" "${USER_HOME}/.ssh"
chmod 600 "${USER_HOME}/.ssh/id_rsa" "${USER_HOME}/.ssh/authorized_keys" "${USER_HOME}/.ssh/config"

# Add to Open OnDemand Apache htpasswd
echo "${PASSWORD}" | htpasswd -i -B "${HTPASSWD_FILE}" "${USERNAME}"
echo "Added ${USERNAME} to Open OnDemand (${HTPASSWD_FILE})"

# Add to Slurm accounting if enabled
SACCTMGR="/opt/slurm/bin/sacctmgr"
if [ -x "${SACCTMGR}" ] && "${SACCTMGR}" show cluster -n &>/dev/null; then
    "${SACCTMGR}" add user "${USERNAME}" account=workshop -i || true
fi

echo "✓ Workshop user '${USERNAME}' provisioned! Password: '${PASSWORD}'"
