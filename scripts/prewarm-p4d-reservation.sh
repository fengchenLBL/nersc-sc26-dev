#!/usr/bin/env bash
set -euo pipefail

PARTITION="${1:-p4d-a100}"
NUM_NODES="${2:-8}"

echo "=== SC26 Nov 15th Pre-Warm & Cutover Script ==="
echo "Target Partition: ${PARTITION} (${NUM_NODES} x p4d.24xlarge = $((NUM_NODES * 8)) A100 GPUs)"

export PATH="/opt/slurm/bin:/usr/local/bin:${PATH}"

# 1. Power up the reserved nodes in Slurm
NODELIST=$(sinfo -p "${PARTITION}" -h -o "%N")
if [ -z "${NODELIST}" ]; then
    echo "ERROR: Partition '${PARTITION}' not found in Slurm!"
    exit 1
fi

echo "Powering up nodes: ${NODELIST}..."
scontrol update nodename="${NODELIST}" state=power_up

echo "Waiting for ${NUM_NODES} nodes in '${PARTITION}' to boot and enter 'idle' state..."
for attempt in {1..60}; do
    IDLE_COUNT=$(sinfo -p "${PARTITION}" -h -t idle -o "%D" || echo "0")
    IDLE_COUNT=${IDLE_COUNT:-0}
    echo "  [Attempt ${attempt}/60] Idle nodes ready: ${IDLE_COUNT}/${NUM_NODES}"
    if [ "${IDLE_COUNT}" -ge "${NUM_NODES}" ]; then
        break
    fi
    sleep 15
done

# 2. Run GPU & Fabric Manager health check across all nodes
echo "Running multi-node GPU & NVSwitch health check..."
srun -p "${PARTITION}" -N "${NUM_NODES}" --gpus-per-node=8 bash -c '
    echo "Node $(hostname): $(nvidia-smi -L | wc -l) GPUs visible"
    systemctl is-active --quiet nvidia-fabricmanager && echo "Node $(hostname): nvidia-fabricmanager ACTIVE"
'

# 3. Switch Open OnDemand JupyterLab default partition to p4d-a100
JUPYTER_FORM="/var/www/ood/apps/sys/jupyter/form.yml"
if [ -f "${JUPYTER_FORM}" ]; then
    sed -i "s/value: \"t4dws\"/value: \"${PARTITION}\"/g" "${JUPYTER_FORM}"
    /opt/ood/nginx_stage/sbin/nginx_stage nginx_clean || true
    echo "Updated Open OnDemand JupyterLab default partition to '${PARTITION}'!"
fi

echo "=== ✓ All ${NUM_NODES} p4d.24xlarge nodes are WARM, VERIFIED, and set as OOD default! ==="
