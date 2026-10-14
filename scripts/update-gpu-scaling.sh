#!/usr/bin/env bash
set -euo pipefail

# Helper script to update Static (Always-Running) and Dynamic (Autoscaling) GPU node counts
# across the Multi-Region Federated Cluster (us-west-2a, us-west-2c, us-east-2a)
#
# Default configuration:
#   - 3 Static (Always-Running) T4 GPUs: 1 in us-west-2a, 1 in us-west-2c, 1 in us-east-2a
#   - 7 Dynamic (Autoscaling) T4 GPUs across the queues (Total = 10 GPUs)
#
# Usage:
#   bash scripts/update-gpu-scaling.sh [STATIC_PER_ZONE] [DYNAMIC_PER_ZONE] [DYNAMIC_DEFAULT_POOL_PER_REGION]
# Example (Default: 1 static per zone = 3 static, 1 dynamic per zone + 2 dynamic default pool per region = 7 dynamic):
#   bash scripts/update-gpu-scaling.sh 1 1 2

STATIC_PER_ZONE="${1:-1}"
DYNAMIC_PER_ZONE="${2:-1}"
DYNAMIC_POOL_PER_REGION="${3:-2}"

MAX_PER_ZONE=$((STATIC_PER_ZONE + DYNAMIC_PER_ZONE))
TOTAL_STATIC=$((STATIC_PER_ZONE * 3))
TOTAL_DYNAMIC=$((DYNAMIC_PER_ZONE * 3 + DYNAMIC_POOL_PER_REGION * 2))
TOTAL_GPUS=$((TOTAL_STATIC + TOTAL_DYNAMIC))

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -x "${SCRIPT_DIR}/.venv/bin/pcluster" ]; then
    PCLUSTER_BIN="${SCRIPT_DIR}/.venv/bin/pcluster"
elif [ -x "${SCRIPT_DIR}/../.venv/bin/pcluster" ]; then
    PCLUSTER_BIN="${SCRIPT_DIR}/../.venv/bin/pcluster"
else
    PCLUSTER_BIN="pcluster"
fi

echo "======================================================================"
echo " Updating Federated GPU Scaling Configuration"
echo "  - Static (Always-Running) GPUs : ${TOTAL_STATIC} (${STATIC_PER_ZONE} each in us-west-2a, us-west-2c, us-east-2a)"
echo "  - Dynamic (Autoscaling) GPUs   : ${TOTAL_DYNAMIC} (${DYNAMIC_PER_ZONE}/zone + ${DYNAMIC_POOL_PER_REGION}/region overflow)"
echo "  - Total Federated GPUs         : ${TOTAL_GPUS}"
echo "======================================================================"

python3 - "${SCRIPT_DIR}/config/sc26-test-gpu.yaml" "${SCRIPT_DIR}/config/sc26-east-gpu.yaml" "${STATIC_PER_ZONE}" "${MAX_PER_ZONE}" "${DYNAMIC_POOL_PER_REGION}" <<'PYEOF'
import sys, re

west_cfg, east_cfg = sys.argv[1], sys.argv[2]
static_z, max_z, pool_max = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])

def update_yaml(path, is_west):
    with open(path, "r") as f:
        text = f.read()
    text = re.sub(
        r'(- Name: t4gpu\n(?:.*?\n)*?\s+MinCount:\s*)\d+(\n\s+MaxCount:\s*)\d+',
        rf'\g<1>0\g<2>{pool_max}',
        text
    )
    for res_name in (["t4usw2a", "t4usw2c"] if is_west else ["t4use2a"]):
        text = re.sub(
            rf'(- Name: {res_name}\n(?:.*?\n)*?\s+MinCount:\s*)\d+(\n\s+MaxCount:\s*)\d+',
            rf'\g<1>{static_z}\g<2>{max_z}',
            text
        )
    with open(path, "w") as f:
        f.write(text)

update_yaml(west_cfg, True)
update_yaml(east_cfg, False)
print("Updated YAML configs successfully.")
PYEOF

echo "[1/4] Requesting compute fleet STOP on sc26-west and sc26-east..."
"${PCLUSTER_BIN}" update-compute-fleet --cluster-name sc26-west --region us-west-2 --status STOP_REQUESTED >/dev/null 2>&1 || true
"${PCLUSTER_BIN}" update-compute-fleet --cluster-name sc26-east --region us-east-2 --status STOP_REQUESTED >/dev/null 2>&1 || true

while true; do
    W_FL=$("${PCLUSTER_BIN}" describe-compute-fleet --cluster-name sc26-west --region us-west-2 | python3 -c "import sys, json; print(json.load(sys.stdin).get('status',''))")
    E_FL=$("${PCLUSTER_BIN}" describe-compute-fleet --cluster-name sc26-east --region us-east-2 | python3 -c "import sys, json; print(json.load(sys.stdin).get('status',''))")
    echo "  Compute fleet status -> sc26-west: ${W_FL} | sc26-east: ${E_FL}"
    if [ "${W_FL}" = "STOPPED" ] && [ "${E_FL}" = "STOPPED" ]; then
        break
    fi
    sleep 10
done

echo "[2/4] Updating cluster configurations on sc26-west and sc26-east..."
"${PCLUSTER_BIN}" update-cluster --cluster-name sc26-west --region us-west-2 --cluster-configuration "${SCRIPT_DIR}/config/sc26-test-gpu.yaml" >/dev/null
"${PCLUSTER_BIN}" update-cluster --cluster-name sc26-east --region us-east-2 --cluster-configuration "${SCRIPT_DIR}/config/sc26-east-gpu.yaml" >/dev/null

while true; do
    W_ST=$("${PCLUSTER_BIN}" describe-cluster --cluster-name sc26-west --region us-west-2 | python3 -c "import sys, json; print(json.load(sys.stdin).get('clusterStatus',''))")
    E_ST=$("${PCLUSTER_BIN}" describe-cluster --cluster-name sc26-east --region us-east-2 | python3 -c "import sys, json; print(json.load(sys.stdin).get('clusterStatus',''))")
    echo "  Cluster status -> sc26-west: ${W_ST} | sc26-east: ${E_ST}"
    if [ "${W_ST}" = "UPDATE_COMPLETE" ] && [ "${E_ST}" = "UPDATE_COMPLETE" ]; then
        break
    fi
    if [[ "${W_ST}" == *"FAILED"* ]] || [[ "${E_ST}" == *"FAILED"* ]]; then
        echo "ERROR: Cluster update failed!"
        exit 1
    fi
    sleep 20
done

echo "[3/4] Starting compute fleets (provisioning ${TOTAL_STATIC} static T4 GPU nodes across 3 zones)..."
"${PCLUSTER_BIN}" update-compute-fleet --cluster-name sc26-west --region us-west-2 --status START_REQUESTED >/dev/null 2>&1 || true
"${PCLUSTER_BIN}" update-compute-fleet --cluster-name sc26-east --region us-east-2 --status START_REQUESTED >/dev/null 2>&1 || true

while true; do
    W_FL=$("${PCLUSTER_BIN}" describe-compute-fleet --cluster-name sc26-west --region us-west-2 | python3 -c "import sys, json; print(json.load(sys.stdin).get('status',''))")
    E_FL=$("${PCLUSTER_BIN}" describe-compute-fleet --cluster-name sc26-east --region us-east-2 | python3 -c "import sys, json; print(json.load(sys.stdin).get('status',''))")
    echo "  Compute fleet status -> sc26-west: ${W_FL} | sc26-east: ${E_FL}"
    if [ "${W_FL}" = "RUNNING" ] && [ "${E_FL}" = "RUNNING" ]; then
        break
    fi
    sleep 10
done

echo "[4/4] Re-verifying Multi-Region Slurm Federation (sc26-fed) and Open OnDemand..."
WEST_PUB_IP=$("${PCLUSTER_BIN}" describe-cluster --cluster-name sc26-west --region us-west-2 | python3 -c "import sys, json; print(json.load(sys.stdin)['headNode']['publicIpAddress'])")
WEST_PRIV_IP=$("${PCLUSTER_BIN}" describe-cluster --cluster-name sc26-west --region us-west-2 | python3 -c "import sys, json; print(json.load(sys.stdin)['headNode']['privateIpAddress'])")
EAST_PUB_IP=$("${PCLUSTER_BIN}" describe-cluster --cluster-name sc26-east --region us-east-2 | python3 -c "import sys, json; print(json.load(sys.stdin)['headNode']['publicIpAddress'])")
EAST_PRIV_IP=$("${PCLUSTER_BIN}" describe-cluster --cluster-name sc26-east --region us-east-2 | python3 -c "import sys, json; print(json.load(sys.stdin)['headNode']['privateIpAddress'])")
bash "${SCRIPT_DIR}/scripts/setup-slurm-federation.sh" "${WEST_PUB_IP}" "${WEST_PRIV_IP}" "${EAST_PUB_IP}" "${EAST_PRIV_IP}"
echo "=== GPU Scaling Update Complete! ==="
