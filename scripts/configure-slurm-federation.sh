#!/usr/bin/env bash
set -euo pipefail

# Configure Slurm Federation across multiple AWS regions (e.g., us-west-2 and us-east-1)
# Run this on the HeadNode connected to the shared SlurmDBD accounting database.

FEDERATION_NAME="${1:-sc26-fed}"
CLUSTERS="${2:-sc26-uswest2,sc26-useast1}"

export PATH="/opt/slurm/bin:/usr/local/bin:${PATH}"

echo "=== Configuring Multi-Region Slurm Federation: ${FEDERATION_NAME} ==="
echo "Clusters: ${CLUSTERS}"

sacctmgr add federation "${FEDERATION_NAME}" -i || true
sacctmgr modify federation "${FEDERATION_NAME}" set clusters="${CLUSTERS}" -i

echo "=== Verifying Federation Status ==="
sacctmgr show federation
scontrol show federation

echo "✓ Slurm Federation '${FEDERATION_NAME}' active! Jobs submitted via sbatch will automatically route to available regional GPUs."
