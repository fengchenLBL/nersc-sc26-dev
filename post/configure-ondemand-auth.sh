#!/usr/bin/env bash
set -euo pipefail

echo "=== Configuring Open OnDemand Authentication on AWS ParallelCluster ==="

if [ ! -s /shared/etc/users.list ]; then
    echo "ERROR: /shared/etc/users.list not found. Run setup/create-users.sh first."
    exit 1
fi

HTPASSWD_FILE="/etc/httpd/.htpasswd"
rm -f "${HTPASSWD_FILE}"

FIRST=1
while IFS=: read -r USERNAME USER_UID PASSWORD; do
    [ -z "${USERNAME}" ] && continue
    if [ "${FIRST}" -eq 1 ]; then
        htpasswd -bc "${HTPASSWD_FILE}" "${USERNAME}" "${PASSWORD}"
        FIRST=0
    else
        htpasswd -b "${HTPASSWD_FILE}" "${USERNAME}" "${PASSWORD}"
    fi
done < /shared/etc/users.list

chown root:apache "${HTPASSWD_FILE}"
chmod 640 "${HTPASSWD_FILE}"
echo "Created ${HTPASSWD_FILE} from /shared/etc/users.list (100 users)"

# Detect AWS HeadNode Public IP via IMDSv2 (fallback to IMDSv1 / hostname -I)
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)
if [ -n "${TOKEN}" ]; then
    EXTERNAL_IP=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/public-ipv4 || true)
else
    EXTERNAL_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || true)
fi

if [ -z "${EXTERNAL_IP}" ] || [[ "${EXTERNAL_IP}" == *"<?xml"* ]]; then
    EXTERNAL_IP=$(hostname -I | awk '{print $1}')
fi
echo "Detected Server IP/Hostname: ${EXTERNAL_IP}"

cat <<EOF > /etc/ood/config/ood_portal.yml
---
# Open OnDemand Portal Configuration (SC26 AWS Workshop)

auth:
  - 'AuthType Basic'
  - 'AuthName "SC26 Workshop - Enter your username and password"'
  - 'AuthBasicProvider file'
  - 'AuthUserFile "/etc/httpd/.htpasswd"'
  - 'Require valid-user'

user_env: 'REMOTE_USER'
servername: ${EXTERNAL_IP}

passenger_min_instances: 1
passenger_start_timeout: 600

# CRITICAL (SC25 Fix #2): Use '[^/]+' instead of '.*' so numbered JupyterLab JS bundles are not mistaken for ports!
host_regex: '[^/]+'
node_uri: '/node'
rnode_uri: '/rnode'
EOF

echo "Regenerating Apache configuration via ood-portal-generator..."
/opt/ood/ood-portal-generator/sbin/update_ood_portal --force

mkdir -p /etc/systemd/system/httpd.service.d
cat <<'EOF' > /etc/systemd/system/httpd.service.d/ood-workshop.conf
[Service]
Environment="OOD_DASHBOARD_TITLE=SC26 Workshop (NERSC-AWS)"
Environment="RAILS_RELATIVE_URL_ROOT=/pun/sys/dashboard"
EOF

DASHBOARD_ENV="/etc/ood/config/apps/dashboard/env"
mkdir -p "$(dirname "${DASHBOARD_ENV}")"
cat <<'EOF' > "${DASHBOARD_ENV}"
DISABLE_CSRF=1
OOD_DASHBOARD_TITLE="SC26 Workshop (NERSC-AWS)"
EOF

mkdir -p /etc/ood/config/ondemand.d
cat <<'EOF' > /etc/ood/config/ondemand.d/ondemand.yml
---
dashboard_title: "SC26 Workshop (NERSC-AWS)"
EOF

mkdir -p /etc/ood/config/apps/dashboard/initializers
cat <<'EOF' > /etc/ood/config/apps/dashboard/initializers/ood.rb
Rails.application.config.after_initialize do
  OodFilesApp.candidate_favorite_paths.tap do |paths|
    scratch_dir = "/shared/users/#{User.new.name}"
    paths << FavoritePath.new(scratch_dir, title: "Scratch") if Dir.exist?(scratch_dir)
  end
end
EOF

systemctl daemon-reload
systemctl restart httpd </dev/null >/dev/null 2>&1
/opt/ood/nginx_stage/sbin/nginx_stage nginx_clean --force >/dev/null 2>&1 || true
pkill -f "Passenger RubyApp" >/dev/null 2>&1 || true

USER1_PASS=$(awk -F: '$1=="user1"{print $3}' /shared/etc/users.list)
echo "=== Open OnDemand Authentication Ready! ==="
echo "Access URL: http://${EXTERNAL_IP}"
echo "Admin Credential Sheet: /root/workshop-credentials.csv"
echo "Sample Login (user1): user1 / ${USER1_PASS}"
