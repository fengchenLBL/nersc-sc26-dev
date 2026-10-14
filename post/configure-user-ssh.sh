#!/usr/bin/env bash
set -euo pipefail

echo "=== Configuring Passwordless SSH & Sample GPU Slurm Scripts for user1..user100 ==="

for i in $(seq 1 100); do
    USERNAME="user${i}"
    USER_HOME="/home/${USERNAME}"

    if [ ! -d "${USER_HOME}" ]; then
        continue
    fi

    SSH_DIR="${USER_HOME}/.ssh"
    mkdir -p "${SSH_DIR}"

    if [ ! -f "${SSH_DIR}/id_rsa" ]; then
        ssh-keygen -t rsa -b 2048 -f "${SSH_DIR}/id_rsa" -N "" -q
    fi

    cat "${SSH_DIR}/id_rsa.pub" > "${SSH_DIR}/authorized_keys"

    cat <<'EOF' > "${SSH_DIR}/config"
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile=/dev/null
    LogLevel ERROR
EOF

    chown -R "${USERNAME}:${USERNAME}" "${SSH_DIR}"
    chmod 700 "${SSH_DIR}"
    chmod 600 "${SSH_DIR}/id_rsa" "${SSH_DIR}/authorized_keys" "${SSH_DIR}/config"
    chmod 644 "${SSH_DIR}/id_rsa.pub"

    # Provide ready-to-run sample GPU Slurm job script
    cat <<'EOF' > "${USER_HOME}/example-job.sh"
#!/bin/bash
#SBATCH --job-name=sc26-gpu-test
#SBATCH --output=output_%j.txt
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=1
#SBATCH --time=00:10:00

echo "=== Hello from SC26 AWS Federated GPU Slurm Cluster! ==="
echo "Job ID: $SLURM_JOB_ID (Cluster: ${SLURM_CLUSTER_NAME:-local}, Partition: ${SLURM_JOB_PARTITION})"
echo "Running on node: $(hostname)"
echo "Availability Zone: $(ec2-metadata -z 2>/dev/null || curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone || echo 'unknown')"
echo "Date: $(date)"
nvidia-smi
EOF

    cat <<'EOF' > "${USER_HOME}/run_pytorch_test.sh"
#!/bin/bash
#SBATCH --job-name=pytorch-gpu-check
#SBATCH --nodes=1
#SBATCH --gpus-per-node=1
#SBATCH --time=00:15:00
#SBATCH --output=pytorch_%j.out

echo "=== Slurm Job: PyTorch GPU Validation ==="
echo "Cluster: ${SLURM_CLUSTER_NAME:-local} | Partition: ${SLURM_JOB_PARTITION}"
echo "Host: $(hostname)"
echo "Allocated GPUs: $CUDA_VISIBLE_DEVICES"

/deploy/jupyter/venv/bin/python - << 'PYEOF'
import torch
print("=== PyTorch GPU Validation ===")
print("PyTorch Version:", torch.__version__)
print("CUDA Available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("Device Count:", torch.cuda.device_count())
    for idx in range(torch.cuda.device_count()):
        print(f"GPU {idx}: {torch.cuda.get_device_name(idx)}")
    x = torch.randn(4096, 4096, device="cuda")
    y = torch.matmul(x, x)
    torch.cuda.synchronize()
    print("Matrix multiplication completed on CUDA! Shape:", y.shape, "mean:", f"{y.mean().item():.4f}")
else:
    raise RuntimeError("CUDA GPU was expected on this GPU node but torch.cuda.is_available() is False!")
print("✓ PyTorch GPU validation PASSED!")
PYEOF
EOF

    chmod +x "${USER_HOME}/example-job.sh" "${USER_HOME}/run_pytorch_test.sh"
    chown "${USERNAME}:${USERNAME}" "${USER_HOME}/example-job.sh" "${USER_HOME}/run_pytorch_test.sh"
done

echo "=== SSH & Sample GPU Slurm Scripts Configured for user1..user100! ==="
