#!/usr/bin/env bash
set -euo pipefail

echo "=== Configuring Slurm Accounting Associations (if slurmdbd is enabled) ==="

SACCTMGR="/opt/slurm/bin/sacctmgr"
if [ ! -x "${SACCTMGR}" ]; then
    SACCTMGR="/usr/local/bin/sacctmgr"
fi

if ! "${SACCTMGR}" show cluster -n &>/dev/null; then
    echo "NOTE: slurmdbd accounting is not enabled on this cluster (standard Slurm queue scheduling works without slurmdbd). Skipping sacctmgr user registration."
    exit 0
fi

"${SACCTMGR}" add account workshop Description="SC26 Workshop Account" -i || true

for i in {1..100}; do
    "${SACCTMGR}" add user "user${i}" account=workshop -i || true
done

"${SACCTMGR}" show user
echo "=== Slurm Accounting Configured! ==="
