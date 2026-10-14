# NERSC SC26 Workshop — Multi-Region Federated GPU Cluster on AWS ParallelCluster

This repository provides a reproducible, automated deployment blueprint for the **NERSC SC26 HPC & AI Workshop** on AWS using **AWS ParallelCluster 3.15.0 (Slurm 25.05.5)**, **Open OnDemand 4.1**, **PyTorch + CUDA + JupyterLab**, and **Multi-Region / Multi-AZ Slurm Federation (`us-west-2a`, `us-west-2c`, `us-east-2a`)**.

> [!TIP]
> For a deep architectural dive (including the 6-phase lifecycle, hybrid Amazon EFS + GP3 NVMe storage layout, and multi-region Slurm Federation internals), see **[SC26_SUMMARY.md](SC26_SUMMARY.md)**.

---

## Architecture Highlights

- **Primary HeadNode (`sc26-west` in `us-west-2a`)**: `m6i.4xlarge` (**16 vCPUs, 64 GiB RAM**, `120 GB` GP3 NVMe SSD) sized to serve **100+ concurrent workshop users** via Open OnDemand Web Portal + SSH.
- **Federated Spoke HeadNode (`sc26-east` in `us-east-2a`)**: `m6i.2xlarge` (**8 vCPUs, 32 GiB RAM**, `100 GB` GP3 NVMe SSD) peered over an AWS Inter-Region VPC Peering link (`172.31.0.0/16` $\leftrightarrow$ `10.2.0.0/16`).
- **GPU-Only Compute Partitions Across 2 Regions & 3 Availability Zones**:
  - `gpu-usw2a`: Pinned to **`us-west-2a`** (Oregon Zone A)
  - `gpu-usw2c`: Pinned to **`us-west-2c`** (Oregon Zone C)
  - `gpu-use2a`: Pinned to **`us-east-2a`** (Ohio Zone A)
  - `gpu` *(Default Federated Queue)*: Spans all 3 Availability Zones across both regions (`us-west-2a`, `us-west-2c`, `us-east-2a`)
- **Zero Static Passwords in Git**: By default, `setup/create-users.sh` generates **cryptographically random 12-character passwords** for `user0..user100` at deployment time and stores them only on the HeadNode in `/root/workshop-credentials.csv` (`chmod 600`).

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

### Step 3: Set Up SSH KeyPairs, Multi-Region VPC Peering & Subnets (Automated)

Run [`scripts/setup-multi-region-network.sh`](scripts/setup-multi-region-network.sh). This single script:
1. Creates the `sc26-key` EC2 SSH KeyPair in `us-west-2` (`~/.ssh/sc26-key.pem`, `chmod 400`) and imports the same public key into `us-east-2`.
2. Discovers your `us-west-2a` and `us-west-2c` Subnet IDs in your `us-west-2` VPC (`172.31.0.0/16`).
3. Creates a non-overlapping VPC (`10.2.0.0/16`) and public subnet (`10.2.1.0/24` in `us-east-2a`) in `us-east-2`.
4. Establishes an active **Inter-Region VPC Peering** connection and bidirectional route table entries between `us-west-2` and `us-east-2`.
5. Automatically populates your discovered Subnet IDs into `config/sc26-test-gpu.yaml` and `config/sc26-east-gpu.yaml`.

```bash
bash scripts/setup-multi-region-network.sh
```

---

### Step 4: Deploy Primary (`sc26-west`) and Spoke (`sc26-east`) GPU Clusters

Launch both AWS ParallelCluster stacks in parallel:

```bash
source .venv/bin/activate

# 1. Primary West Cluster (us-west-2a & us-west-2c, m6i.4xlarge HeadNode + g4dn.xlarge T4 GPUs)
pcluster create-cluster \
  --cluster-name sc26-west \
  --cluster-configuration config/sc26-test-gpu.yaml \
  --region us-west-2

# 2. Federated East Spoke Cluster (us-east-2a, m6i.2xlarge HeadNode + g4dn.xlarge T4 GPUs)
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
   - Generates a unique, cryptographically random 12-character alphanumeric password for each user (`user1`..`user100`) using `openssl rand`.
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
   - Open `http://${WEST_PUB_IP}` in your browser and log in with `user1` and the password from `workshop-credentials.csv`.
   - Launch an interactive **Shell** or **JupyterLab + PyTorch GPU** session.

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

### Step 8: Production Cutover (`p4d.24xlarge` A100 GPUs on Nov 15) & Teardown

- **Production Cutover (`p4d.24xlarge` Capacity Blocks)**:
  Edit [`config/sc26-workshop-prod.yaml`](config/sc26-workshop-prod.yaml) to insert NERSC's `CapacityReservationId` (`cr-xxxxxxxx`) values for `us-west-2a`, `us-west-2c`, and `us-east-2a`, and run [`scripts/prewarm-p4d-reservation.sh`](scripts/prewarm-p4d-reservation.sh) on the morning of the workshop.
- **Teardown (Stop All Billing After Workshop)**:
  ```bash
  pcluster delete-cluster --cluster-name sc26-west --region us-west-2
  pcluster delete-cluster --cluster-name sc26-east --region us-east-2
  ```
