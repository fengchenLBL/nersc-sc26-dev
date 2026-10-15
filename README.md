# NERSC SC26 Workshop — Multi-Region Federated GPU Cluster on AWS ParallelCluster

This repository provides a reproducible, automated deployment blueprint for the **NERSC SC26 HPC & AI Workshop** on AWS using **AWS ParallelCluster 3.15.0 (Slurm 25.05.5)**, **Open OnDemand 4.1**, **PyTorch + CUDA + JupyterLab**, and **Multi-Region / Multi-AZ Slurm Federation (`us-west-2a`, `us-west-2c`, `us-east-2a`)**.

> [!TIP]
> For a deep architectural dive (including the 6-phase lifecycle, hybrid Amazon EFS + GP3 NVMe storage layout, and multi-region Slurm Federation internals), see **[SC26_SUMMARY.md](SC26_SUMMARY.md)**.

---

## Architecture Highlights

- **Primary HeadNode (`sc26-west` in `us-west-2a`)**: `m6i.4xlarge` (**16 vCPUs, 64 GiB RAM**, **`1,000 GB (1 TB)` GP3 NVMe SSD**) sized to serve **100+ concurrent workshop users** via Open OnDemand Web Portal + SSH without ever needing to resize `/home` or `/deploy`.
- **Federated Spoke HeadNode (`sc26-east` in `us-east-2a`)**: `m6i.2xlarge` (**8 vCPUs, 32 GiB RAM**, **`1,000 GB (1 TB)` GP3 NVMe SSD**) peered over an AWS Inter-Region VPC Peering link (`172.31.0.0/16` $\leftrightarrow$ `10.2.0.0/16`).
- **7 GPU-Only Compute Partitions Across 2 Regions & 3 Availability Zones**:
  - **Tesla T4 Partitions (`g4dn.xlarge` — 3 Warm Static + 7 Dynamic GPUs for Everyday Testing & Overflow)**:
    - `gpu-usw2a`: Pinned to **`us-west-2a`** (Oregon Zone A — `1` warm static + `1` dynamic T4)
    - `gpu-usw2c`: Pinned to **`us-west-2c`** (Oregon Zone C — `1` warm static + `1` dynamic T4)
    - `gpu-use2a`: Pinned to **`us-east-2a`** (Ohio Zone A — `1` warm static + `1` dynamic T4)
    - `gpu` *(Default Federated Queue)*: Spans all 3 Availability Zones across both regions (`us-west-2a`, `us-west-2c`, `us-east-2a`)
  - **NVIDIA A100 Partitions (`p4d.24xlarge` — 8 × A100 GPUs + 4 × 100 Gbps EFA per Node)**:
    - `a100-usw2a`: Pinned to **`us-west-2a`** (`0..8` in placeholder mode; `2 × p4d.24xlarge` = 16 A100s on Oct 23; `8 × p4d.24xlarge` = 64 A100s on Nov 15)
    - `a100-usw2c`: Pinned to **`us-west-2c`** (`0..7` in placeholder mode; `7 × p4d.24xlarge` = 56 A100s on Nov 15)
    - `a100-use2a`: Pinned to **`us-east-2a`** (`0..7` in placeholder mode; `2 × p4d.24xlarge` = 16 A100s on Oct 23; `7 × p4d.24xlarge` = 56 A100s on Nov 15)
- **Zero Static Passwords in Git**: By default, `setup/create-users.sh` generates **cryptographically random 12-character passwords** for `user0..user100` (101 users, UIDs `2000..2100`) at deployment time and stores them only on the HeadNode in `/root/workshop-credentials.csv` (`chmod 600`), plus dedicated per-user `$SCRATCH` directories at `/shared/users/user<N>` (`chmod 700`).

---

## Step-by-Step Reproduction Guide

### Step 1: Create AWS IAM Deployer User & Access Keys

1. Sign in to the **AWS Management Console** $\rightarrow$ **IAM** $\rightarrow$ **Policies** $\rightarrow$ **Create policy**.
2. Select the **JSON** tab and paste the contents of [`iam/sc26-deployer-policy.json`](iam/sc26-deployer-policy.json). Name the policy `SC26ParallelClusterDeployerPolicy`.
3. Go to **IAM** $\rightarrow$ **Users** $\rightarrow$ **Create user** (e.g., `sc26-deployer`).
4. Choose **Attach policies directly**, select `SC26ParallelClusterDeployerPolicy`, and create the user.
5. Open the user $\rightarrow$ **Security credentials** tab $\rightarrow$ **Create access key** $\rightarrow$ choose **Command Line Interface (CLI)** and copy your **Access Key ID** and **Secret Access Key**.

*(Note: Ensure your AWS account has sufficient EC2 On-Demand vCPU quotas in `us-west-2` and `us-east-2` for Standard (`m6i`) and G/VT (`g4dn.xlarge`) instances).*

---

### Step 2: Configure AWS CLI & Install AWS ParallelCluster CLI

1. Install and configure the AWS CLI with your IAM Access Key and Secret Key:
   ```bash
   aws configure
   # AWS Access Key ID [None]: <YOUR_AWS_ACCESS_KEY_ID>
   # AWS Secret Access Key [None]: <YOUR_AWS_SECRET_ACCESS_KEY>
   # Default region name [None]: us-west-2
   # Default output format [None]: json
   ```
   Verify your identity:
   ```bash
   aws sts get-caller-identity
   ```

2. Create an isolated Python virtual environment and install `aws-parallelcluster` and `nodeenv`:
   ```bash
   python3 -m venv .venv
   source .venv/bin/activate
   pip install --upgrade pip
   pip install -r requirements.txt
   pcluster version
   ```

---

### Step 3: Set Up SSH KeyPairs, Multi-Region VPC Peering, Gateway Endpoints & Subnets (Automated)

Run [`scripts/setup-multi-region-network.sh`](scripts/setup-multi-region-network.sh). This single script:
1. Creates the `sc26-key` EC2 SSH KeyPair in `us-west-2` (`~/.ssh/sc26-key.pem`, `chmod 400`) and imports the same public key into `us-east-2`.
2. Discovers your `us-west-2a` and `us-west-2c` Subnet IDs in your `us-west-2` VPC (`172.31.0.0/16`).
3. Creates a non-overlapping VPC (`10.2.0.0/16`) and subnet (`10.2.1.0/24` in `us-east-2a`) in `us-east-2`.
4. Establishes an active **Inter-Region VPC Peering** connection and bidirectional route table entries between `us-west-2` and `us-east-2`.
5. Creates **free S3 & DynamoDB Gateway VPC Endpoints** in both regions and configures subnet attributes for 4-NIC `p4d.24xlarge` (`AssignPublicIp: false`) compatibility.
6. Automatically populates your discovered Subnet IDs into `config/sc26-test-gpu.yaml` and `config/sc26-east-gpu.yaml`.

```bash
bash scripts/setup-multi-region-network.sh
```

---

### Step 4: Deploy Primary (`sc26-west`) and Spoke (`sc26-east`) GPU Clusters

Launch both AWS ParallelCluster stacks in parallel (by default, the 3 `a100-*` partitions start in `placeholder` mode at `MinCount: 0` so deployment succeeds immediately in any AWS account):

```bash
source .venv/bin/activate

# 1. Primary West Cluster (us-west-2a & us-west-2c, m6i.4xlarge HeadNode + T4 & A100 partitions)
pcluster create-cluster \
  --cluster-name sc26-west \
  --cluster-configuration config/sc26-test-gpu.yaml \
  --region us-west-2

# 2. Federated East Spoke Cluster (us-east-2a, m6i.2xlarge HeadNode + T4 & A100 partitions)
pcluster create-cluster \
  --cluster-name sc26-east \
  --cluster-configuration config/sc26-east-gpu.yaml \
  --region us-east-2
```

#### Monitor Deployment Progress (~12–15 minutes)
```bash
pcluster describe-cluster --cluster-name sc26-west --region us-west-2 --query "clusterStatus"
pcluster describe-cluster --cluster-name sc26-east --region us-east-2 --query "clusterStatus"
```

Once both report `"CREATE_COMPLETE"`, retrieve their Public and Private IPs:
```bash
WEST_PUB_IP=$(pcluster describe-cluster --cluster-name sc26-west --region us-west-2 --query "headNode.publicIpAddress" --output text)
WEST_PRIV_IP=$(pcluster describe-cluster --cluster-name sc26-west --region us-west-2 --query "headNode.privateIpAddress" --output text)
EAST_PUB_IP=$(pcluster describe-cluster --cluster-name sc26-east --region us-east-2 --query "headNode.publicIpAddress" --output text)
EAST_PRIV_IP=$(pcluster describe-cluster --cluster-name sc26-east --region us-east-2 --query "headNode.privateIpAddress" --output text)

echo "sc26-west: Public=${WEST_PUB_IP}, Private=${WEST_PRIV_IP}"
echo "sc26-east: Public=${EAST_PUB_IP}, Private=${EAST_PRIV_IP}"
```

---

### Step 5: Configure Users, Software Stack & Multi-Region Slurm Federation

1. **Upload this repository to both HeadNodes and run the one-shot post-installation script**:
   ```bash
   scp -i ~/.ssh/sc26-key.pem -r . ec2-user@${WEST_PUB_IP}:~/nersc-sc26
   scp -i ~/.ssh/sc26-key.pem -r . ec2-user@${EAST_PUB_IP}:~/nersc-sc26

   # Run one-shot post-install on Primary West HeadNode
   ssh -i ~/.ssh/sc26-key.pem ec2-user@${WEST_PUB_IP} "sudo bash ~/nersc-sc26/post/one-shot-post.sh"

   # Run one-shot post-install on Spoke East HeadNode
   ssh -i ~/.ssh/sc26-key.pem ec2-user@${EAST_PUB_IP} "sudo bash ~/nersc-sc26/post/one-shot-post.sh"
   ```

2. **Link `sc26-west` and `sc26-east` into a Unified Slurm Federation (`sc26-fed`)**:
   ```bash
   bash scripts/setup-slurm-federation.sh "${WEST_PUB_IP}" "${WEST_PRIV_IP}" "${EAST_PUB_IP}" "${EAST_PRIV_IP}"
   ```
   This script automatically:
   - Opens HTTP/HTTPS (80/443) for Open OnDemand and cross-region VPC traffic (`172.31.0.0/16` $\leftrightarrow$ `10.2.0.0/16`).
   - Synchronizes `/etc/munge/munge.key` and `/shared/etc/users.list` across both regions.
   - Mounts `/home/user0..user100` across regions over NFSv4.1 (`/federated_home`).
   - Configures `slurmdbd` + MariaDB and joins `sc26-west` and `sc26-east` into `sc26-fed`.

---

### Step 6: Workshop User Passwords & Security (Avoiding Public GitHub Password Leaks)

Because this repository is public, **no static passwords are stored in the repository**. [`setup/create-users.sh`](setup/create-users.sh) supports two secure modes:

1. **Mode A (Default — Unique Random Passwords Per User)**:
   - Generates a unique, cryptographically random 12-character alphanumeric password for each user (`user0`..`user100`) using `openssl rand`.
   - Saves the master credential list on the Primary HeadNode at `/root/workshop-credentials.csv` (`chmod 600`).
   - Download the credential sheet to your laptop to distribute to attendees:
     ```bash
     ssh -i ~/.ssh/sc26-key.pem ec2-user@${WEST_PUB_IP} "sudo cat /root/workshop-credentials.csv" > workshop-credentials.csv
     chmod 600 workshop-credentials.csv
     head -n 6 workshop-credentials.csv
     ```

2. **Mode B (Optional — Custom Event Secret Prefix Passed at Runtime)**:
   - If you prefer a memorable prefix for a live tutorial without ever committing it to GitHub, pass `WORKSHOP_PASSWORD_PREFIX` when running `one-shot-post.sh`:
     ```bash
     ssh -i ~/.ssh/sc26-key.pem ec2-user@${WEST_PUB_IP} \
       "sudo WORKSHOP_PASSWORD_PREFIX='MySecretEventCode-' bash ~/nersc-sc26/post/one-shot-post.sh"
     ```

---

### Step 7: Validate Federated GPU Execution & Open OnDemand

1. **Access Open OnDemand Web Portal**:
   - Open `https://${WEST_PUB_IP}` in your browser and log in with `user0` or `user1` and the password from `workshop-credentials.csv`.
   - Launch an interactive **Shell** or **JupyterLab + PyTorch GPU** session (all 7 partitions — `gpu`, `gpu-usw2a`, `gpu-usw2c`, `gpu-use2a`, `a100-usw2a`, `a100-usw2c`, `a100-use2a` — are available in the Slurm Partition dropdown).

2. **Submit PyTorch CUDA GPU Jobs Across All 3 Region-Zones (`us-west-2a`, `us-west-2c`, `us-east-2a`)**:
   ```bash
   ssh -i ~/.ssh/sc26-key.pem ec2-user@${WEST_PUB_IP} "sudo su - user1 -c '
     sbatch -p gpu-usw2a -J test-usw2a ~/run_pytorch_test.sh
     sbatch -p gpu-usw2c -J test-usw2c ~/run_pytorch_test.sh
     sbatch -M sc26-east -p gpu-use2a -J test-use2a ~/run_pytorch_test.sh
     sbatch -p gpu -J test-fed-default ~/run_pytorch_test.sh
     squeue --federation
   '"
   ```

---

### Step 8: Capacity Block Cutover (`p4d.24xlarge` A100 GPUs on Oct 23 & Nov 15) & Teardown

Use [`scripts/configure-a100-partitions.sh`](scripts/configure-a100-partitions.sh) to switch the 3 `a100-*` partitions (`a100-usw2a`, `a100-usw2c`, `a100-use2a`) between **`placeholder` mode** (`MinCount: 0`), **`oct23` dress-rehearsal mode** (2 AZs: `4 × p4d.24xlarge` = 32 A100 GPUs), and **`nov15` SC26 workshop mode** (3 AZs: `22 × p4d.24xlarge` = 176 A100 GPUs) without interrupting the running T4 GPUs:

1. **Oct 23, 2026 Dress Rehearsal Cutover (`04:30 AM PDT` = `06:30 AM CDT` Chicago = `11:30 UTC`)**:
   ```bash
   # Activate 2x p4d.24xlarge in us-west-2a + 2x p4d.24xlarge in us-east-2a (32x A100 GPUs total)
   bash scripts/configure-a100-partitions.sh oct23 <USW2A_OCT23_CB_ID> <USE2A_OCT23_CB_ID> --apply

   # Re-apply Slurm federation & Open OnDemand config on sc26-west
   bash scripts/setup-slurm-federation.sh "${WEST_PUB_IP}" "${WEST_PRIV_IP}" "${EAST_PUB_IP}" "${EAST_PRIV_IP}"
   ssh -i ~/.ssh/sc26-key.pem ec2-user@${WEST_PUB_IP} "sudo bash ~/nersc-sc26/setup/configure-ondemand-cluster.sh"

   # Verify all 4x p4d.24xlarge nodes (32x A100 GPUs) + NVSwitch Fabric Manager
   ssh -i ~/.ssh/sc26-key.pem ec2-user@${WEST_PUB_IP} "sudo bash ~/nersc-sc26/scripts/prewarm-p4d-reservation.sh oct23"

   # After the Oct 23 test finishes, return to placeholder mode (MinCount: 0)
   bash scripts/configure-a100-partitions.sh placeholder --apply
   ```

2. **Nov 15, 2026 SC26 Workshop Production Cutover (`03:30 AM PST` = `05:30 AM CST` Chicago = `11:30 UTC`)**:
   ```bash
   # Activate 8x p4d in us-west-2a + 7x p4d in us-west-2c + 7x p4d in us-east-2a (22x p4d.24xlarge = 176x A100 GPUs)
   bash scripts/configure-a100-partitions.sh nov15 <USW2A_NOV15_CB_ID> <USW2C_NOV15_CB_ID> <USE2A_NOV15_CB_ID> --apply

   # Re-apply Slurm federation & Open OnDemand config on sc26-west
   bash scripts/setup-slurm-federation.sh "${WEST_PUB_IP}" "${WEST_PRIV_IP}" "${EAST_PUB_IP}" "${EAST_PRIV_IP}"
   ssh -i ~/.ssh/sc26-key.pem ec2-user@${WEST_PUB_IP} "sudo bash ~/nersc-sc26/setup/configure-ondemand-cluster.sh"

   # Verify all 22x p4d.24xlarge nodes (176x A100 GPUs) + NVSwitch Fabric Manager
   ssh -i ~/.ssh/sc26-key.pem ec2-user@${WEST_PUB_IP} "sudo bash ~/nersc-sc26/scripts/prewarm-p4d-reservation.sh nov15"
   ```

3. **Teardown (Stop All Billing After Workshop)**:
   ```bash
   pcluster delete-cluster --cluster-name sc26-west --region us-west-2
   pcluster delete-cluster --cluster-name sc26-east --region us-east-2
   ```
