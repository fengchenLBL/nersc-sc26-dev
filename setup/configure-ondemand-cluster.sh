#!/usr/bin/env bash
set -euo pipefail

echo "=== Configuring Open OnDemand Cluster & Interactive Apps for AWS ParallelCluster ==="

SLURM_BIN="/opt/slurm/bin"
SLURM_CONF="/opt/slurm/etc/slurm.conf"
if [ ! -d "${SLURM_BIN}" ]; then
    SLURM_BIN="/usr/local/bin"
    SLURM_CONF="/etc/slurm/slurm.conf"
fi

# Detect active default Slurm partition on this cluster
DEFAULT_PARTITION=$(${SLURM_BIN}/sinfo -h -o "%P" 2>/dev/null | grep '\*' | tr -d '*' | head -n1 || true)
if [ -z "${DEFAULT_PARTITION}" ]; then
    DEFAULT_PARTITION=$(${SLURM_BIN}/sinfo -h -o "%P" 2>/dev/null | head -n1 || echo "gpu")
fi
DEFAULT_GPUS="1"
if [ "${DEFAULT_PARTITION}" = "cpu-test" ]; then
    DEFAULT_GPUS="0"
fi
echo "Detected default Slurm partition: ${DEFAULT_PARTITION} (default GPUs=${DEFAULT_GPUS})"

# 1. Configure Cluster Definition
mkdir -p /etc/ood/config/clusters.d
cat <<EOF > /etc/ood/config/clusters.d/sc26-workshop.yml
---
v2:
  metadata:
    title: "SC26 AWS ParallelCluster Federated GPU Workshop"
  login:
    host: "localhost"
  job:
    adapter: "slurm"
    bin: "${SLURM_BIN}"
    conf: "${SLURM_CONF}"
EOF
chmod 644 /etc/ood/config/clusters.d/sc26-workshop.yml

# 2. Configure OOD Shell App Environment & Host Allowlist (SC25 Fix #1)
mkdir -p /etc/ood/config/apps/shell
cat <<'EOF' > /etc/ood/config/apps/shell/env
OOD_DEFAULT_SSHHOST="localhost"
OOD_SSHHOST_ALLOWLIST="localhost:127.0.0.1:ip-*:gpu-*:t4dws-*:p4d-*:cpu-*"
EOF
chmod 644 /etc/ood/config/apps/shell/env

# 3. Configure Jupyter Interactive App (including manifest.yml so OOD shows it in Interactive Apps dropdown!)
JUPYTER_APP_DIR="/var/www/ood/apps/sys/jupyter"
mkdir -p "${JUPYTER_APP_DIR}/template"

cat <<'EOF' > "${JUPYTER_APP_DIR}/manifest.yml"
---
name: Jupyter Lab
category: Interactive Apps
subcategory: Servers
role: batch_connect
description: |
  This app will launch a Jupyter Lab or Jupyter Notebook server with PyTorch + CUDA on a Slurm GPU node across us-west-2a, us-west-2c, or us-east-2a.
EOF
chmod 644 "${JUPYTER_APP_DIR}/manifest.yml"

cat <<EOF > "${JUPYTER_APP_DIR}/form.yml"
---
cluster: "sc26-workshop"
attributes:
  partition:
    widget: "select"
    label: "Slurm GPU Partition (Federated Queue)"
    options:
      - [ "Oregon Zone A GPU - us-west-2a (1 Static + 1 Dynamic T4) [gpu-usw2a]", "gpu-usw2a" ]
      - [ "Oregon Zone C GPU - us-west-2c (1 Static + 1 Dynamic T4) [gpu-usw2c]", "gpu-usw2c" ]
      - [ "Ohio Zone A GPU - us-east-2a (1 Static + 1 Dynamic T4) [gpu-use2a]", "gpu-use2a" ]
      - [ "Auto Federated Dynamic GPU Pool (4 Dynamic T4 across West & East) [gpu]", "gpu" ]
    value: "gpu-usw2a"
  bc_num_hours:
    widget: "number_field"
    label: "Number of hours"
    value: 2
    min: 1
    max: 8
    step: 1
  num_nodes:
    widget: "number_field"
    label: "Number of nodes"
    value: 1
    min: 1
    max: 8
  num_gpus:
    widget: "number_field"
    label: "Number of GPUs per node"
    value: ${DEFAULT_GPUS}
    min: 1
    max: 8
    step: 1
    help: "Test T4 nodes (g4dn.xlarge): 1 GPU per node | Prod A100 nodes (p4d.24xlarge): up to 8 GPUs per node"
  mode:
    widget: "radio"
    value: "1"
    options:
      - ["Jupyter Lab", "1"]
      - ["Jupyter Notebook", "0"]
  working_dir:
    widget: "path_selector"
    label: "Root Directory"
    help: "Select your project directory; defaults to \$HOME"
    show_hidden: false
    show_files: false

form:
  - partition
  - bc_num_hours
  - num_nodes
  - num_gpus
  - mode
  - working_dir
EOF

cat <<'EOF' > "${JUPYTER_APP_DIR}/submit.yml.erb"
---
batch_connect:
  template: "basic"
  conn_params:
    - jupyter_api
script:
  native:
<% if partition == "gpu-use2a" %>
    - "-M"
    - "sc26-east"
    - "-p"
    - "gpu-use2a"
<% else %>
    - "-p"
    - "<%= partition.blank? ? 'gpu' : partition %>"
<% end %>
    - "-N"
    - "<%= num_nodes.blank? ? 1 : num_nodes.to_i %>"
    - "-t"
    - "<%= bc_num_hours.blank? ? 1 : bc_num_hours.to_i %>:00:00"
<% if partition != "cpu-test" && !num_gpus.blank? && num_gpus.to_i > 0 %>
    - "--gpus-per-node=<%= num_gpus.to_i %>"
<% end %>
EOF

cat <<'EOF' > "${JUPYTER_APP_DIR}/template/before.sh.erb"
# Export the module function if it exists
[[ $(type -t module) == "function" ]] && export -f module

# Find available port to run server on
port=$(find_port)

# Generate SHA1 encrypted password (requires OpenSSL installed)
SALT="$(create_passwd 16)"
password="$(create_passwd 16)"
PASSWORD_SHA1="$(echo -n "${password}${SALT}" | openssl dgst -sha1 | awk '{print $NF}')"

# The $CONFIG_FILE environment variable is exported as it is used in the main
# `script.sh.erb` file when launching the Jupyter Notebook server.
export CONFIG_FILE="${PWD}/config.py"

# Generate Jupyter configuration file with secure file permissions
(
umask 077
cat > "${CONFIG_FILE}" << EOL
c.ServerApp.ip = '*'
c.ServerApp.port = ${port}
c.ServerApp.port_retries = 0
c.PasswordIdentityProvider.hashed_password = u'sha1:${SALT}:${PASSWORD_SHA1}'
c.ServerApp.base_url = '/node/${host}/${port}/'
c.ServerApp.open_browser = False
c.ServerApp.allow_origin = '*'
c.ServerApp.root_dir = '${HOME}'
c.ServerApp.disable_check_xsrf = True
EOL
)
EOF

cat <<'EOF' > "${JUPYTER_APP_DIR}/template/script.sh.erb"
#!/usr/bin/env bash

echo "TIMING - Starting main script at: $(date)"

<%
  working_dir = Pathname.new(context.working_dir)
  if ! working_dir.exist?
    working_dir = Pathname.new(ENV['HOME'])
  elsif working_dir.file?
    working_dir = working_dir.parent
  end
%>

cd "<%= working_dir.to_s %>"

echo "TIMING - Starting jupyter at: $(date)"

set -x
if [ -x /deploy/jupyter/venv/bin/jupyter ]; then
    JUPYTER_BIN="/deploy/jupyter/venv/bin/jupyter"
elif [ -x /opt/slurm/deploy/jupyter/venv/bin/jupyter ]; then
    JUPYTER_BIN="/opt/slurm/deploy/jupyter/venv/bin/jupyter"
elif [ -x /shared/deploy/jupyter/venv/bin/jupyter ]; then
    JUPYTER_BIN="/shared/deploy/jupyter/venv/bin/jupyter"
else
    JUPYTER_BIN="jupyter"
fi

${JUPYTER_BIN} <%= context.mode == "1" ? "lab" : "notebook" %> --config="${CONFIG_FILE}"
EOF

cat <<'EOF' > "${JUPYTER_APP_DIR}/template/after.sh.erb"
echo "Waiting for Jupyter server to open port ${port}..."
echo "TIMING - Starting wait at: $(date)"
if wait_until_port_used "${host}:${port}" 120; then
  echo "Discovered Jupyter server listening on port ${port}!"
  echo "TIMING - Wait ended at: $(date)"
else
  echo "Timed out waiting for Jupyter server to open port ${port}!"
  echo "TIMING - Wait ended at: $(date)"
  pkill -P ${SCRIPT_PID}
  clean_up 1
fi
sleep 2
EOF

chmod +x "${JUPYTER_APP_DIR}/template/before.sh.erb" "${JUPYTER_APP_DIR}/template/script.sh.erb" "${JUPYTER_APP_DIR}/template/after.sh.erb"

# 4. Patch ood_core slurm.rb so get_cluster_info:
#    - Uses nodehost:40 (prevents >20 char AWS ParallelCluster node names like gpu-usw2a-dy-t4usw2a-1 from colliding with gres column!)
#    - Queries --federation so all federated regions/zones are counted in the OOD Cluster Status widget!
SLURM_RB=$(find /opt/ood/ondemand/root/usr/share/gems -name "slurm.rb" 2>/dev/null | head -n 1 || true)
if [ -n "${SLURM_RB}" ] && [ -f "${SLURM_RB}" ]; then
    cp -n "${SLURM_RB}" "${SLURM_RB}.orig" || true
    python3 - "${SLURM_RB}" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, "r") as f:
    content = f.read()

target = """          def get_cluster_info
            node_cpu_info = call("sinfo", "-aho %A/%D/%C").strip.split('/')
            gres_length = call("sinfo", "-o %G").lines.map(&:strip).map(&:length).max + 2
            gres_lines = call("sinfo", "-ahNO ,nodehost,gres:#{gres_length},gresused:#{gres_length}")
                         .lines.uniq.map(&:split)
            ClusterInfo.new(active_nodes: node_cpu_info[0].to_i,
                            total_nodes: node_cpu_info[2].to_i,
                            active_processors: node_cpu_info[3].to_i,
                            total_processors: node_cpu_info[6].to_i,
                            active_gpus: gres_lines.sum { |line| Slurm.gpus_from_gres(line[2]) },
                            total_gpus: gres_lines.sum { |line| Slurm.gpus_from_gres(line[1]) }
            )
          end"""

replacement = """          def get_cluster_info
            fed_lines = call("sinfo", "--federation", "-aho", "%A/%D/%C").lines.map(&:strip).reject(&:empty?)
            active_n = fed_lines.sum { |l| l.split('/')[0].to_i }
            total_n  = fed_lines.sum { |l| l.split('/')[2].to_i }
            active_c = fed_lines.sum { |l| l.split('/')[3].to_i }
            total_c  = fed_lines.sum { |l| l.split('/')[6].to_i }
            gres_length = call("sinfo", "--federation", "-o", "%G").lines.map(&:strip).map(&:length).max + 2
            gres_lines = call("sinfo", "--federation", "-ahNO", ",cluster,nodehost:40,gres:#{gres_length},gresused:#{gres_length}")
                         .lines.uniq.map(&:split)
            ClusterInfo.new(active_nodes: active_n,
                            total_nodes: total_n,
                            active_processors: active_c,
                            total_processors: total_c,
                            active_gpus: gres_lines.sum { |line| Slurm.gpus_from_gres(line[3]) },
                            total_gpus: gres_lines.sum { |line| Slurm.gpus_from_gres(line[2]) }
            )
          end"""

if target in content:
    content = content.replace(target, replacement)
    with open(path, "w") as f:
        f.write(content)
    print(f"Patched {path} with nodehost:40 and --federation support!")
else:
    print(f"{path} already patched or target not found.")
PYEOF
fi

# Restart active Per-User NGINX (PUN) processes so dashboard immediately reflects changes
/opt/ood/nginx_stage/sbin/nginx_stage nginx_clean --force >/dev/null 2>&1 || true
pkill -f "Passenger RubyApp" >/dev/null 2>&1 || true

echo "=== Open OnDemand Cluster & Jupyter App Configuration Complete! ==="
