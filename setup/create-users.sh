#!/usr/bin/env bash
set -euo pipefail

echo "=== Creating SC26 Workshop Users (user1..user100) with Deterministic UIDs ==="
echo "Security Mode: Generates cryptographically random per-user passwords by default"
echo "  (or uses WORKSHOP_PASSWORD_PREFIX if explicitly set at runtime, never stored in Git)."

mkdir -p /shared/etc /shared/users
chmod 755 /shared/users
ln -sfn /shared /share
CREDENTIALS_CSV="/root/workshop-credentials.csv"

cat <<'EOF' > /etc/profile.d/sc26-scratch.sh
# Automatically set per-user isolated $SCRATCH space on shared EFS
if [ -n "${USER:-}" ] && [ -d "/share/users/${USER}" ]; then
    export SCRATCH="/share/users/${USER}"
elif [ -n "${USER:-}" ] && [ -d "/shared/users/${USER}" ]; then
    export SCRATCH="/shared/users/${USER}"
fi
EOF
chmod 644 /etc/profile.d/sc26-scratch.sh

# Preserve existing /shared/etc/users.list if already generated (e.g. synced from primary HeadNode)
if [ -s /shared/etc/users.list ] && [ "$(wc -l < /shared/etc/users.list)" -ge 100 ]; then
    echo "Using existing /shared/etc/users.list..."
else
    > /shared/etc/users.list
    echo "username,uid,password" > "${CREDENTIALS_CSV}"
    chmod 600 "${CREDENTIALS_CSV}"

    for i in {1..100}; do
        username="user${i}"
        uid=$((2000 + i))
        if [ -n "${WORKSHOP_PASSWORD_PREFIX:-}" ]; then
            password="${WORKSHOP_PASSWORD_PREFIX}${i}"
        else
            # Generate unique 12-character random alphanumeric password per user
            password=$(openssl rand -base64 24 | tr -dc 'A-HJ-NP-Za-km-z2-9' | head -c 12)
        fi
        echo "${username}:${uid}:${password}" >> /shared/etc/users.list
        echo "${username},${uid},${password}" >> "${CREDENTIALS_CSV}"
    done
    chmod 600 /shared/etc/users.list
fi

while IFS=: read -r username uid password; do
    [ -z "${username}" ] && continue

    if ! getent group "$username" &>/dev/null; then
        groupadd -g "$uid" "$username" || true
    fi

    if ! id "$username" &>/dev/null; then
        useradd -m -u "$uid" -g "$uid" -s /bin/bash "$username"
        echo "Created user: $username (UID=$uid)"
    fi

    echo "${username}:${password}" | chpasswd

    mkdir -p "/home/${username}/.ssh"
    chmod 700 "/home/${username}/.ssh"
    chown -R "${uid}:${uid}" "/home/${username}/.ssh"

    # Dedicated per-user $SCRATCH directory on shared EFS (chmod 700: accessible ONLY by matching user)
    mkdir -p "/shared/users/${username}"
    chown "${uid}:${uid}" "/shared/users/${username}"
    chmod 700 "/shared/users/${username}"

    if [ -f "/home/${username}/.bashrc" ] && ! grep -q 'export SCRATCH=' "/home/${username}/.bashrc"; then
        echo 'export SCRATCH="/share/users/${USER}"' >> "/home/${username}/.bashrc"
        chown "${uid}:${uid}" "/home/${username}/.bashrc"
    fi

    cat > "/home/${username}/README.txt" <<EOF
Welcome to the SC26 AWS HPC Workshop!

Username: ${username}
Dedicated Scratch Space (\$SCRATCH): /share/users/${username}

You can:
- Use your private large-file scratch folder: cd \$SCRATCH (/share/users/${username})
- Submit Slurm jobs: sbatch example-job.sh
- Submit GPU PyTorch validation jobs: sbatch run_pytorch_test.sh
- Check job status across the federation: squeue
- Check partitions and nodes across the federation: sinfo

Happy computing!
EOF
    chown "${uid}:${uid}" "/home/${username}/README.txt"
done < /shared/etc/users.list

echo "All 100 workshop users created!"
echo "  - Cluster sync file: /shared/etc/users.list (chmod 600)"
echo "  - Per-user Scratch: /share/users/user1..user100 (chmod 700)"
echo "  - Admin credential sheet: ${CREDENTIALS_CSV} (chmod 600)"
