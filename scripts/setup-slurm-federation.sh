#!/usr/bin/env bash
set -euo pipefail

KEY_FILE="${SSH_KEY_FILE:-${HOME}/.ssh/sc26-key.pem}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${KEY_FILE}"

if [ "$#" -lt 4 ]; then
    echo "Usage: $0 <WEST_PUBLIC_IP> <WEST_PRIVATE_IP> <EAST_PUBLIC_IP> <EAST_PRIVATE_IP>"
    exit 1
fi

WEST_PUB_IP=$1
WEST_PRIV_IP=$2
EAST_PUB_IP=$3
EAST_PRIV_IP=$4

echo "=== 1. Opening Security Groups for Open OnDemand (80/443) & Inter-Region VPC Peering (172.31.0.0/16 <-> 10.2.0.0/16) ==="
WEST_SGS=$(aws ec2 describe-security-groups --region us-west-2 --filters "Name=tag:parallelcluster:cluster-name,Values=sc26-west" --query "SecurityGroups[].GroupId" --output text)
for sg in ${WEST_SGS}; do
    aws ec2 authorize-security-group-ingress --region us-west-2 --group-id "${sg}" --protocol -1 --cidr "10.2.0.0/16" >/dev/null 2>&1 || true
    aws ec2 authorize-security-group-ingress --region us-west-2 --group-id "${sg}" --protocol tcp --port 80 --cidr "0.0.0.0/0" >/dev/null 2>&1 || true
    aws ec2 authorize-security-group-ingress --region us-west-2 --group-id "${sg}" --protocol tcp --port 443 --cidr "0.0.0.0/0" >/dev/null 2>&1 || true
done

EAST_SGS=$(aws ec2 describe-security-groups --region us-east-2 --filters "Name=tag:parallelcluster:cluster-name,Values=sc26-east" --query "SecurityGroups[].GroupId" --output text)
for sg in ${EAST_SGS}; do
    aws ec2 authorize-security-group-ingress --region us-east-2 --group-id "${sg}" --protocol -1 --cidr "172.31.0.0/16" >/dev/null 2>&1 || true
done
echo "Security Groups updated in us-west-2 and us-east-2!"

echo "=== 2. Synchronizing Munge Key & User Credentials (sc26-west -> sc26-east) ==="
ssh ${SSH_OPTS} ec2-user@"${WEST_PUB_IP}" "sudo cat /etc/munge/munge.key" > /tmp/sc26_munge.key
ssh ${SSH_OPTS} ec2-user@"${WEST_PUB_IP}" "sudo cat /shared/etc/users.list" > /tmp/sc26_users.list
scp ${SSH_OPTS} /tmp/sc26_munge.key /tmp/sc26_users.list ec2-user@"${EAST_PUB_IP}":/tmp/
rm -f /tmp/sc26_munge.key /tmp/sc26_users.list

ssh ${SSH_OPTS} ec2-user@"${EAST_PUB_IP}" "sudo bash -c '
    cp /tmp/sc26_munge.key /etc/munge/munge.key
    chown munge:munge /etc/munge/munge.key
    chmod 0600 /etc/munge/munge.key
    cp /tmp/sc26_munge.key /opt/parallelcluster/shared/.munge/.munge.key
    chown root:root /opt/parallelcluster/shared/.munge/.munge.key
    chmod 0600 /opt/parallelcluster/shared/.munge/.munge.key
    mkdir -p /shared/etc
    cp /tmp/sc26_users.list /shared/etc/users.list
    chmod 0600 /shared/etc/users.list
    rm -f /tmp/sc26_munge.key /tmp/sc26_users.list
    systemctl restart munge
'"
echo "Munge key and /shared/etc/users.list unified across sc26-west and sc26-east!"

echo "=== 3. Configuring Cross-Region /etc/hosts & Unified /home/user1..user100 ==="
WEST_HOSTNAME=$(ssh ${SSH_OPTS} ec2-user@"${WEST_PUB_IP}" "hostname -s")
EAST_HOSTNAME=$(ssh ${SSH_OPTS} ec2-user@"${EAST_PUB_IP}" "hostname -s")

ssh ${SSH_OPTS} ec2-user@"${WEST_PUB_IP}" "sudo bash -c '
    grep -q \"${EAST_PRIV_IP}\" /etc/hosts || echo \"${EAST_PRIV_IP} ${EAST_HOSTNAME}\" >> /etc/hosts
    if ! grep -q \"10.2.0.0/16\" /etc/exports; then
        sed -i \"s|^/home .*|/home 172.31.0.0/16(rw,sync,no_root_squash) 10.2.0.0/16(rw,async,no_root_squash)|\" /etc/exports
        exportfs -ra
    fi
'"

ssh ${SSH_OPTS} ec2-user@"${EAST_PUB_IP}" "sudo bash -c '
    grep -q \"${WEST_PRIV_IP}\" /etc/hosts || echo \"${WEST_PRIV_IP} ${WEST_HOSTNAME}\" >> /etc/hosts
    mkdir -p /federated_home
    if ! mountpoint -q /federated_home; then
        mount -t nfs4 -o rw,nfsvers=4.1 ${WEST_PRIV_IP}:/home /federated_home
    fi
    grep -q \"/federated_home\" /etc/fstab || echo \"${WEST_PRIV_IP}:/home /federated_home nfs4 rw,nfsvers=4.1,_netdev 0 0\" >> /etc/fstab
    for i in \$(seq 1 100); do
        u=\"user\${i}\"
        if [ -d \"/home/\${u}\" ] && [ ! -L \"/home/\${u}\" ]; then
            rm -rf \"/home/\${u}\"
        fi
        ln -sfn \"/federated_home/\${u}\" \"/home/\${u}\"
    done
    echo \"${WEST_PRIV_IP}\" > /shared/etc/west_headnode_ip
'"
echo "Cross-region /federated_home mounted and linked on sc26-east!"

echo "=== 4. Configuring MariaDB & slurmdbd on sc26-west (${WEST_PRIV_IP}:6819) ==="
DB_PASS=$(openssl rand -hex 12)
ssh ${SSH_OPTS} ec2-user@"${WEST_PUB_IP}" "sudo bash -c '
    systemctl enable mariadb </dev/null >/dev/null 2>&1
    systemctl start mariadb </dev/null >/dev/null 2>&1

    mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS slurm_acct_db;
CREATE USER IF NOT EXISTS \"slurm\"@\"localhost\" IDENTIFIED BY \"${DB_PASS}\";
ALTER USER \"slurm\"@\"localhost\" IDENTIFIED BY \"${DB_PASS}\";
GRANT ALL ON slurm_acct_db.* TO \"slurm\"@\"localhost\";
FLUSH PRIVILEGES;
SQL

    cat <<EOF > /opt/slurm/etc/slurmdbd.conf
AuthType=auth/munge
DbdAddr=${WEST_PRIV_IP}
DbdHost=${WEST_HOSTNAME}
DbdPort=6819
SlurmUser=slurm
LogFile=/var/log/slurmdbd.log
PidFile=/var/run/slurmdbd.pid
StorageType=accounting_storage/mysql
StorageHost=localhost
StoragePass=${DB_PASS}
StorageUser=slurm
StorageLoc=slurm_acct_db
EOF
    chown slurm:slurm /opt/slurm/etc/slurmdbd.conf
    chmod 600 /opt/slurm/etc/slurmdbd.conf

    cat <<EOF > /etc/systemd/system/slurmdbd.service
[Unit]
Description=Slurm DBD accounting daemon
After=network-online.target munge.service mariadb.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/slurm/sbin/slurmdbd -D -s
ExecReload=/bin/kill -HUP \$MAINPID
LimitNOFILE=65536
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable slurmdbd </dev/null >/dev/null 2>&1
    systemctl restart slurmdbd </dev/null >/dev/null 2>&1
    sleep 3
'"

echo "=== 5. Pointing sc26-west and sc26-east slurmctld to slurmdbd & Creating Federation (sc26-fed) ==="
for IP in "${WEST_PUB_IP}" "${EAST_PUB_IP}"; do
    ssh ${SSH_OPTS} ec2-user@"${IP}" "sudo bash -c '
        cat <<EOF > /opt/slurm/etc/pcluster/custom_slurm_settings_include_file_slurm.conf
AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=${WEST_PRIV_IP}
AccountingStoragePort=6819
EOF
        chown slurm:slurm /opt/slurm/etc/pcluster/custom_slurm_settings_include_file_slurm.conf
        cat <<EOF > /etc/profile.d/sc26-federation.sh
alias sinfo=\"sinfo --federation\"
alias squeue=\"squeue --federation\"
EOF
        chmod 644 /etc/profile.d/sc26-federation.sh
    '"
done

ssh ${SSH_OPTS} ec2-user@"${WEST_PUB_IP}" "sudo bash -c '
    /opt/slurm/bin/sacctmgr -i add cluster sc26-west || true
    /opt/slurm/bin/sacctmgr -i add cluster sc26-east || true
    rm -f /var/spool/slurm.state/clustername
    systemctl restart slurmctld
'"

ssh ${SSH_OPTS} ec2-user@"${EAST_PUB_IP}" "sudo bash -c '
    rm -f /var/spool/slurm.state/clustername
    systemctl restart slurmctld
'"
sleep 3

ssh ${SSH_OPTS} ec2-user@"${WEST_PUB_IP}" "sudo bash -c '
    /opt/slurm/bin/sacctmgr -i add federation sc26-fed clusters=sc26-west,sc26-east || /opt/slurm/bin/sacctmgr -i modify federation sc26-fed set clusters=sc26-west,sc26-east || true
    systemctl restart slurmctld
'"
ssh ${SSH_OPTS} ec2-user@"${EAST_PUB_IP}" "sudo systemctl restart slurmctld"
sleep 3

echo "=== 6. Verifying Slurm Federation Status ==="
ssh ${SSH_OPTS} ec2-user@"${WEST_PUB_IP}" "/opt/slurm/bin/scontrol show fed && /opt/slurm/bin/sinfo --federation"
