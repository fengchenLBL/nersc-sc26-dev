# SC26 AWS ParallelCluster + Multi-Region Slurm Federation + Open OnDemand: High-Level Architecture, Storage, Workflow & Cost Summary

## 1. Overview

This project migrates and extends the [SC25 GCP Slurm Workshop (`SC25_SUMMARY.md`)](file:///Users/fengchenliu/makabaka/SC25-NERSC/SC25_SUMMARY.md) to **Amazon Web Services (AWS)** for the **SC26 NERSC Workshop** ([`nersc-sc26`](file:///Users/fengchenliu/makabaka/SC25-NERSC/nersc-sc26)).

Unlike a single-zone cluster, the SC26 workshop GPU reservations span **multiple AWS Regions and Availability Zones (`us-west-2a`, `us-west-2c`, and `us-east-2a`)**. To give 100+ workshop participants a **single login node, a single unified `/home` directory, and transparent multi-region GPU scheduling**, this architecture combines:

- **AWS ParallelCluster v3.15.0 (RHEL 8 + Slurm 25.11.8)**: Two coordinated GPU-only clusters (`sc26-west` in Oregon `us-west-2` and `sc26-east` in Ohio `us-east-2`) with elastic dynamic autoscaling (`MinCount: 0`).
- **Slurm Federation (`sc26-fed`) + Shared `slurmdbd`**: Links `sc26-west` and `sc26-east` into a single federated Slurm scheduler domain with unified Munge authentication (`munge.key`), federated queue visibility (`sinfo --federation`, `squeue --federation`), and federated job accounting (`sacct --federation`).
- **Inter-Region VPC Peering + Unified Cross-Region `/home` NFS**: Connects `us-west-2` (`172.31.0.0/16`) and `us-east-2` (`10.2.0.0/16`) over AWS backbone peering so that jobs running in **any** region (`us-west-2a`, `us-west-2c`, or `us-east-2a`) read and write directly to the participant's `/home/user<N>` directory on `sc26-west`.
- **Beefy Primary HeadNode (`m6i.4xlarge` — 16 vCPUs, 64 GiB RAM, 120 GB GP3 NVMe SSD)**: Sized to comfortably host **100+ concurrent workshop users** (`user1..user100`) across SSH and Open OnDemand Per-User NGINX (PUN) processes.
- **Open OnDemand (OOD) v4.0.11**: Zero-install browser portal offering one-click GPU JupyterLab (Batch Connect), Web Shell Terminal, Visual File Manager, and Job Composer.
- **Hybrid Storage Architecture (Amazon EFS `8.0 Exabyte` Elastic NFS + GP3 NVMe SSD)**: Combines serverless, infinitely elastic **Amazon EFS (`/shared`)** for shared cluster scripts/datasets with high-IOPS **GP3 NVMe EBS (`/opt/slurm/deploy` & `/home`)** for fast Python/PyTorch environment loading and low-latency user home directories.

> [!IMPORTANT]
> All sensitive information (external IP addresses, individual user credentials, VPC/Subnet IDs, and internal host details) has been sanitized and replaced with generic placeholders (`<WEST_HEADNODE_PUBLIC_IP>`, `<EAST_HEADNODE_PUBLIC_IP>`, `<WEST_PRIVATE_IP>`, `<EAST_PRIVATE_IP>`, `user<N>`, `<WORKSHOP_PASSWORD>`) in this public summary.

---

## 2. High-Level Architecture & Storage Design

```mermaid
flowchart TD
    subgraph Internet ["Public Internet / 100+ Workshop Participants"]
        UserBrowser["Participant Web Browser<br/>(HTTP / HTTPS Port 80/443)"]
        UserSSH["CLI / Terminal Access<br/>(SSH Port 22)"]
    end

    subgraph USWest2 ["AWS Region: us-west-2 (Oregon) — VPC: 172.31.0.0/16 (sc26-west)"]
        subgraph WestHead ["Primary Login, Federation & Storage Hub (us-west-2a)"]
            HeadNodeWest["sc26-west HeadNode (m6i.4xlarge: 16 vCPU, 64 GiB RAM)<br/>Public IP: WEST_HEADNODE_PUBLIC_IP | Private IP: WEST_PRIVATE_IP<br/>• Open OnDemand v4.0.11 + Apache + 100x Per-User NGINX<br/>• Primary slurmctld + Central slurmdbd (Port 6819) + MariaDB<br/>• 120 GB GP3 NVMe SSD: /home NFS Export & /opt/slurm/deploy/jupyter/venv (6.0 GB)"]
        end

        subgraph WestEFS ["Amazon EFS (us-west-2)"]
            EFSWest["Amazon EFS (/shared)<br/>Elastic Capacity (8.0 Exabytes virtual, pay-per-GB)<br/>• Mounted across us-west-2a & us-west-2c<br/>• Shared scripts (/shared/deploy) & user registry (/shared/etc)"]
        end

        subgraph WestCompute ["us-west-2 Multi-AZ Dynamic GPU Pools (GPU-Only)"]
            WestAZ_A["Availability Zone: us-west-2a<br/>Queues: gpu-usw2a & gpu*<br/>• Dynamic GPU Nodes (g4dn.xlarge T4 / p4d.24xlarge A100)<br/>• Scales 0 -> N on demand"]
            WestAZ_C["Availability Zone: us-west-2c<br/>Queues: gpu-usw2c & gpu*<br/>• Dynamic GPU Nodes (g4dn.xlarge T4 / p4d.24xlarge A100)<br/>• Scales 0 -> N on demand"]
        end
    end

    subgraph USEast2 ["AWS Region: us-east-2 (Ohio) — VPC: 10.2.0.0/16 (sc26-east)"]
        subgraph EastHead ["Federated Spoke Controller (us-east-2a)"]
            HeadNodeEast["sc26-east HeadNode (m6i.2xlarge: 8 vCPU, 32 GiB RAM)<br/>Public IP: EAST_HEADNODE_PUBLIC_IP | Private IP: EAST_PRIVATE_IP<br/>• Spoke slurmctld (Federated Sibling in sc26-fed)<br/>• Shared Munge Key (/etc/munge/munge.key)<br/>• 100 GB GP3 NVMe SSD: Local /opt/slurm/deploy/jupyter/venv (6.0 GB)"]
        end

        subgraph EastEFS ["Amazon EFS (us-east-2)"]
            EFSEast["Amazon EFS (/shared)<br/>Elastic Capacity (8.0 Exabytes virtual, pay-per-GB)<br/>• Mounted in us-east-2a"]
        end

        subgraph EastCompute ["us-east-2 Dynamic GPU Pool (GPU-Only)"]
            EastAZ_A["Availability Zone: us-east-2a<br/>Queues: gpu-use2a & gpu*<br/>• Dynamic GPU Nodes (g4dn.xlarge T4 / p4d.24xlarge A100)<br/>• Scales 0 -> N on demand"]
        end
    end

    UserBrowser -->|"Web Portal (Port 80/443)"| HeadNodeWest
    UserSSH -->|"SSH Login (Port 22)"| HeadNodeWest

    HeadNodeWest -->|"Local Slurm Dispatch + NFS /home + /deploy"| WestAZ_A
    HeadNodeWest -->|"Local Slurm Dispatch + NFS /home + /deploy"| WestAZ_C
    EFSWest ===|"Multi-AZ EFS Mount /shared"| HeadNodeWest
    EFSWest ===|"Multi-AZ EFS Mount /shared"| WestAZ_A
    EFSWest ===|"Multi-AZ EFS Mount /shared"| WestAZ_C

    HeadNodeWest <==>|"Inter-Region VPC Peering<br/>1. Slurm Federation RPC (Ports 6818-6829)<br/>2. Central slurmdbd Accounting (Port 6819)<br/>3. Cross-Region /federated_home NFSv4.1 Mount"| HeadNodeEast

    HeadNodeEast -->|"Local Slurm Dispatch + Local /deploy"| EastAZ_A
    EFSEast ===|"EFS Mount /shared"| HeadNodeEast
    EFSEast ===|"EFS Mount /shared"| EastAZ_A
    HeadNodeWest -.->|"Cross-Region NFSv4.1 /federated_home"| EastAZ_A
```

### 2.1 Architectural Component Summary

| Component | AWS Cluster & Region/AZ | Sizing & Hardware | Role & Responsibilities |
| :--- | :--- | :--- | :--- |
| **Primary HeadNode & OOD Portal** | `sc26-west` (`us-west-2a`) | **`m6i.4xlarge`** (16 vCPUs, 64 GiB RAM, 12.5 Gbps network, 120 GB GP3 NVMe) | Single user entry point for 100+ users; runs Open OnDemand 4.0.11, primary `slurmctld`, central `slurmdbd` + MariaDB, and exports `/home` + `/opt/slurm/deploy`. |
| **Spoke HeadNode (East Controller)** | `sc26-east` (`us-east-2a`) | **`m6i.2xlarge`** (8 vCPUs, 32 GiB RAM, 100 GB GP3 NVMe) | Runs federated sibling `slurmctld` and `clustermgtd` to autoscale EC2 GPU nodes in `us-east-2a`; hosts local `/opt/slurm/deploy/jupyter/venv`. |
| **Oregon Zone-A GPU Pool** | `sc26-west` (`us-west-2a`) | **Test**: `g4dn.xlarge` (1x Tesla T4, 16 GB)<br/>**Prod**: `p4d.24xlarge` (8x A100 40GB + EFA) | Served by Slurm partitions `gpu-usw2a` (zone-pinned) and `gpu` (federated default). Dynamic autoscaling (`0..N`). |
| **Oregon Zone-C GPU Pool** | `sc26-west` (`us-west-2c`) | **Test**: `g4dn.xlarge` (1x Tesla T4, 16 GB)<br/>**Prod**: `p4d.24xlarge` (8x A100 40GB + EFA) | Served by Slurm partitions `gpu-usw2c` (zone-pinned) and `gpu` (federated default). Dynamic autoscaling (`0..N`). |
| **Ohio Zone-A GPU Pool** | `sc26-east` (`us-east-2a`) | **Test**: `g4dn.xlarge` (1x Tesla T4, 16 GB)<br/>**Prod**: `p4d.24xlarge` (8x A100 40GB + EFA) | Served by Slurm partitions `gpu-use2a` (zone-pinned) and `gpu` (federated default). Dynamic autoscaling (`0..N`). |
| **Amazon EFS Shared Storage** | `us-west-2` & `us-east-2` | **Elastic (`8.0 Exabytes` virtual limit)**, General Purpose, encrypted | Serverless multi-AZ NFSv4.1 filesystem mounted at `/shared` across HeadNode and compute nodes. |
| **Inter-Region VPC Peering** | `us-west-2` $\leftrightarrow$ `us-east-2` | `172.31.0.0/16` $\leftrightarrow$ `10.2.0.0/16` | Private AWS backbone link carrying Slurm Federation RPCs, `slurmdbd` accounting, and `/federated_home` NFSv4.1 traffic. |

---

### 2.2 Detailed Storage & File System Architecture (Amazon EFS vs. GP3 NVMe EBS)

A major architectural advantage of **AWS (`SC26`)** over **Google Cloud (`SC25`)** is how shared storage is provisioned, sized, and billed. Whereas GCP Filestore requires pre-allocating a minimum **1 TB (`1,024 GB`)** fixed block at ~\$204.80/month even when empty, AWS combines **serverless, infinitely elastic Amazon EFS (`/shared`)** with **high-IOPS HeadNode GP3 NVMe EBS (`/home` & `/opt/slurm/deploy`)**.

#### Live `df -hT` & Usage Breakdown on `sc26-west` (`m6i.4xlarge` HeadNode)
```text
Filesystem      Type   Size  Used Avail Use% Mounted on
/dev/nvme0n1p3  xfs    120G   43G   78G  36% /          (Includes /home & /opt/slurm/deploy)
127.0.0.1:/     nfs4   8.0E    0G  8.0E   0% /shared    (Amazon EFS via local TLS stunnel proxy)
```
- **Base OS + Slurm + Open OnDemand RPMs (`/`)**: `~37 GB` used
- **Shared Python 3.11 + PyTorch 2.14.1 (`+cu130`) + JupyterLab Virtualenv (`/opt/slurm/deploy/jupyter`)**: `6.0 GB` used (100,000+ small Python/CUDA files)
- **100 Workshop User Home Directories (`/home/user1..user100`)**: `~7 MB` initial (`78 GB` free on the `120 GB` test volume; configurable to `500 GB – 2 TB` in production)
- **Amazon EFS (`/shared`)**: `8.0 Exabytes` (`8,000,000,000 GB`) virtual elastic capacity (`~136 KB` currently used by `/shared/deploy` and `/shared/etc/users.list`)

#### How the 3 Shared Storage Tiers Work Together

| Mount Path | Underlying AWS Storage Technology | Capacity & Sizing | How It Is Shared Across Nodes | Why We Use It for This Specific Role |
| :--- | :--- | :--- | :--- | :--- |
| **`/shared`** | **Amazon EFS (Elastic File System)** | **Serverless & Elastic (`0 GB` to `8.0 Exabytes`)** — No fixed size to pre-allocate! Grows and shrinks automatically as files are added or deleted (\$0.30/GB-month for actual data stored). | Mounted natively via AWS EFS Mount Helper (`nfs4` over `127.0.0.1` TLS proxy) across all AZs (`us-west-2a`, `us-west-2c`). | Ideal for shared cluster config (`/shared/etc/users.list`), deployment scripts (`/shared/deploy/nersc-sc26`), and large read-mostly workshop datasets (`10 GB – 10 TB`) without ever worrying about running out of disk space. |
| **`/opt/slurm/deploy`** *(symlinked at `/deploy`)* | **HeadNode Local GP3 NVMe EBS Volume** | **Part of the `120 GB` GP3 Root Volume** (`6.0 GB` used by PyTorch + CUDA + JupyterLab; `3,000 baseline IOPS`, `125 MB/s` throughput). | AWS ParallelCluster automatically NFS-exports `/opt/slurm` to all local compute nodes; each region (`sc26-west` and `sc26-east`) has its own local NVMe copy. | **15x faster Python/PyTorch installs & imports**: A newly created, empty EFS filesystem in `bursting` throughput mode throttles metadata IOPS when extracting 100,000+ small `pip` files (~20 min). Putting `/deploy/jupyter/venv` on GP3 NVMe cuts `pip install torch jupyterlab` down to **~60 seconds** and gives compute nodes local-region NVMe read speed! |
| **`/home`** *(and `/federated_home`)* | **Primary HeadNode (`sc26-west`) GP3 NVMe EBS Volume** | **`78 GB` available** in Test (`120 GB` root volume); **recommended `500 GB` (`gp3`)** in [`config/sc26-workshop-prod.yaml`](file:///Users/fengchenliu/makabaka/SC25-NERSC/nersc-sc26/config/sc26-workshop-prod.yaml) for 100 workshop users (~5 GB/user). | Exported via Kernel NFSv4.1 from `sc26-west` (`<WEST_PRIVATE_IP>:/home`) to **both** `us-west-2` (`172.31.0.0/16`) and `us-east-2` (`10.2.0.0/16` over VPC Peering at `/federated_home`). | Gives all 100 users a **single unified `/home/user<N>` directory across both Oregon and Ohio**! When a job runs on a GPU in `us-east-2a`, its output file (`pytorch_use2a_*.out`) appears immediately in `/home/user<N>/` on `sc26-west`. |

> [!TIP]
> **How to Scale Storage for the Nov 15 Production Workshop**:
> 1. **To give 100 users more `/home` space**: Increase `HeadNode -> LocalStorage -> RootVolume -> Size` in [`config/sc26-workshop-prod.yaml`](file:///Users/fengchenliu/makabaka/SC25-NERSC/nersc-sc26/config/sc26-workshop-prod.yaml) from `120` to `500` (500 GB GP3 costs only ~\$40/month = **\$1.33/day**).
> 2. **To store large training datasets (e.g., 200 GB – 2 TB) in `/shared` (Amazon EFS)**: No size change is needed because EFS is automatically elastic up to 8 Exabytes! If 100 GPU jobs will read heavy datasets from `/shared` simultaneously, add `ThroughputMode: elastic` under `SharedStorage -> EfsSettings` in the YAML so EFS scales read throughput up to **3 GiB/s** automatically.

---

## 3. How the Federated Cluster Works Under the Hood

### A. End-to-End Participant & Multi-Region Job Lifecycle

```mermaid
sequenceDiagram
    autonumber
    actor User as Workshop Participant (user1..user100)
    participant WestHN as sc26-west HeadNode (us-west-2a)<br/>OOD + slurmctld + slurmdbd + /home
    participant EastHN as sc26-east HeadNode (us-east-2a)<br/>Sibling slurmctld
    participant WestGPU as GPU Compute Node<br/>(us-west-2a or us-west-2c)
    participant EastGPU as GPU Compute Node<br/>(us-east-2a)

    User->>WestHN: Login via Browser (http://WEST_HEADNODE_PUBLIC_IP/) or SSH (userN@WEST_HEADNODE_PUBLIC_IP)
    WestHN->>User: Authenticates userN & mounts /home/userN

    note over User,EastGPU: Case 1: Job Scheduled in us-west-2a or us-west-2c (sc26-west)
    User->>WestHN: Submits job (sbatch -p gpu / gpu-usw2a / gpu-usw2c or OOD JupyterLab)
    WestHN->>WestGPU: AWS ParallelCluster ResumeProgram boots EC2 GPU instance in us-west-2a/2c
    WestGPU->>WestGPU: Slurm Prolog syncs UID/GID, symlinks /deploy -> /opt/slurm/deploy
    WestGPU->>WestHN: Reads input & writes job output directly to /home/userN/

    note over User,EastGPU: Case 2: Job Scheduled in us-east-2a (sc26-east via Slurm Federation)
    User->>WestHN: Submits job from sc26-west (sbatch -p gpu or sbatch -M sc26-east -p gpu-use2a)
    WestHN->>EastHN: Routes federated job over VPC Peering to sibling slurmctld (sc26-east)
    EastHN->>EastGPU: AWS ParallelCluster ResumeProgram boots EC2 GPU instance in us-east-2a
    EastGPU->>WestHN: Slurm Prolog mounts WEST_PRIVATE_IP:/home at /federated_home (/home/userN symlink)
    EastGPU->>EastGPU: Loads PyTorch CUDA from local Ohio NVMe (/opt/slurm/deploy/jupyter/venv)
    EastGPU->>WestHN: Writes output file directly back to /home/userN/ on sc26-west!
```

### B. Five Key Engineering Mechanisms

1. **Unified Munge Authentication Across Regions (`munge.key`)**:
   - AWS ParallelCluster stores a master copy of the Munge key at `/opt/parallelcluster/shared/.munge/.munge.key` and copies it to `/etc/munge/munge.key` on every dynamic compute node at boot (`aws-parallelcluster-slurm/libraries/helpers.rb`).
   - [`scripts/setup-slurm-federation.sh`](file:///Users/fengchenliu/makabaka/SC25-NERSC/nersc-sc26/scripts/setup-slurm-federation.sh) copies `sc26-west`'s `/etc/munge/munge.key` to **both** `/etc/munge/munge.key` and `/opt/parallelcluster/shared/.munge/.munge.key` on `sc26-east`, ensuring that both HeadNodes and all dynamically scaled GPU nodes in `us-west-2a`, `us-west-2c`, and `us-east-2a` trust each other's Slurm credentials.

2. **Cross-Region `/federated_home` Without Breaking Local OS Accounts**:
   - Linux NFS servers cannot re-export a directory (`/home`) that is itself an NFS client mount (`exportfs: /home does not support NFS export`), and `sc26-east` requires its own local `/home/ec2-user` and `/home/slurm`.
   - Solution:
     - `sc26-west` exports `/home` to both `172.31.0.0/16` (`us-west-2`) and `10.2.0.0/16` (`us-east-2`).
     - `sc26-east` HeadNode and `sc26-east` compute nodes (via [`setup/compute-node-setup.sh`](file:///Users/fengchenliu/makabaka/SC25-NERSC/nersc-sc26/setup/compute-node-setup.sh)) mount `<WEST_PRIVATE_IP>:/home` at `/federated_home`.
     - On `sc26-east`, `/home/user1` .. `/home/user100` are symbolic links to `/federated_home/user1` .. `/federated_home/user100`.

3. **Slurm Federation + AWS ParallelCluster `clustermgtd` Compatibility**:
   - AWS ParallelCluster's `clustermgtd` daemon runs `/opt/slurm/bin/sinfo` every 60 seconds to inspect local dynamic nodes.
   - If `FederationParameters=fed_display` is set globally in `slurm.conf`, `sinfo` returns remote sibling nodes and causes `clustermgtd` to reject the output.
   - By omitting `FederationParameters=fed_display` from `slurm.conf` and instead installing `/etc/profile.d/sc26-federation.sh` (`alias sinfo="sinfo --federation"`, `alias squeue="squeue --federation"`), `clustermgtd` scales EC2 instances cleanly in both regions while interactive users automatically see the full federated cluster view.

4. **Dynamic Compute Node User & Package Synchronization via Slurm Prolog**:
   - [`setup/compute-node-setup.sh`](file:///Users/fengchenliu/makabaka/SC25-NERSC/nersc-sc26/setup/compute-node-setup.sh) is registered as a Slurm Prolog (`/opt/slurm/etc/scripts/prolog.d/90_sc26_compute_setup.sh`) so every dynamically booted GPU node automatically gets `/deploy` symlinked, `/federated_home` mounted, `user1..user100` UIDs/GIDs (`2001..2100`) created, and `nmap-ncat` + `python3.11` installed before the user job starts.

5. **On-Demand Capacity Reservation (ODCR) Support for Nov 15 Production**:
   - AWS ParallelCluster natively supports targeting NERSC's pre-reserved GPU blocks in `us-west-2a`, `us-west-2c`, and `us-east-2a` by adding `CapacityReservationTarget: { CapacityReservationId: cr-xxxxx }` under each queue's `ComputeResources` block in [`config/sc26-workshop-prod.yaml`](file:///Users/fengchenliu/makabaka/SC25-NERSC/nersc-sc26/config/sc26-workshop-prod.yaml).

---

## 4. How Workshop Users & Organizers Access the Cluster

### Method 1: Web Browser Access via Open OnDemand (Recommended for Participants)
1. Open a browser and navigate to the `sc26-west` Primary HeadNode:
   ```text
   http://<WEST_HEADNODE_PUBLIC_IP>/
   ```
2. Log in with assigned workshop credentials:
   - **Username**: `<WORKSHOP_USERNAME>` (e.g., `user<N>`)
   - **Password**: `<WORKSHOP_PASSWORD>`
3. Use the top navigation bar:
   - **Interactive Apps $\rightarrow$ Jupyter Lab**: Launches a GPU-backed JupyterLab notebook on a Slurm GPU compute node with the pre-built `SC26 Workshop (PyTorch + GPU)` kernel.
   - **Clusters $\rightarrow$ SC26 Workshop Cluster Shell Access**: Opens an in-browser terminal on `sc26-west`.
   - **Files $\rightarrow$ Home Directory**: Browse, edit, upload, and download files in `/home/user<N>`.
   - **Jobs $\rightarrow$ Active Jobs**: Monitor running and queued jobs across the federation.

### Method 2: Command-Line SSH & Slurm Federation Commands
Participants or instructors can SSH directly into the primary HeadNode:
```bash
ssh <WORKSHOP_USERNAME>@<WEST_HEADNODE_PUBLIC_IP>
```

#### Submitting GPU Jobs Across the Federated Cluster
Every user home directory comes pre-populated with `example-job.sh` and `run_pytorch_test.sh`:
```bash
# 1. Submit to the default federated 'gpu' partition (Slurm Federation schedules automatically)
sbatch -p gpu ~/run_pytorch_test.sh

# 2. Target a specific Availability Zone in Oregon (us-west-2a or us-west-2c)
sbatch -p gpu-usw2a ~/run_pytorch_test.sh
sbatch -p gpu-usw2c ~/run_pytorch_test.sh

# 3. Target Ohio (us-east-2a) directly from the Oregon login node
sbatch -M sc26-east -p gpu-use2a ~/run_pytorch_test.sh
```

#### Monitoring the Federated Cluster
```bash
# View all partitions and GPU node states across both us-west-2 and us-east-2
sinfo --federation

# View all running and queued jobs across both regions
squeue --federation

# View federation controller health and sibling sync state
scontrol show fed

# View completed job accounting across both regions
sacct --federation -a -X -o JobID,JobName%16,User,Cluster,Partition,NodeList%24,State,ExitCode
```

---

## 5. Verification & Testing Performed

All requirements for the multi-region, multi-AZ GPU cluster were verified live on AWS across **`us-west-2a`**, **`us-west-2c`**, and **`us-east-2a`**:

| Test Category | Description & Test Executed | Observed Result | Status |
| :--- | :--- | :--- | :--- |
| **Multi-Region VPC & Peering** | Automated creation of `us-east-2` VPC (`10.2.0.0/16`) and Inter-Region VPC Peering with `us-west-2` (`172.31.0.0/16`). | Bidirectional routing and Security Group rules established between Oregon and Ohio. | **PASSED** |
| **Beefy HeadNode Sizing** | Deployed `sc26-west` HeadNode on **`m6i.4xlarge`** (16 vCPUs, 64 GiB RAM, 120 GB GP3 NVMe SSD). | Provisioned 100 users (`user1..user100`), Open OnDemand 4.0.11, and PyTorch CUDA venv in **~4 minutes**. | **PASSED** |
| **Slurm Federation (`sc26-fed`)** | Linked `sc26-west` and `sc26-east` via central `slurmdbd` (`6819`) and unified `munge.key`. | `scontrol show fed` reports `FedState:ACTIVE`, `PersistConnSend/Recv:Yes/Yes`, `Synced:Yes`. | **PASSED** |
| **Cross-Region `/home` NFS** | Mounted `<WEST_PRIVATE_IP>:/home` at `/federated_home` on `sc26-east` HeadNode and compute nodes. | `user1..user100` see identical files in `/home/user<N>` across `us-west-2a`, `us-west-2c`, and `us-east-2a`. | **PASSED** |
| **Oregon Zone-A GPU (`us-west-2a`)** | Submitted `sbatch -p gpu-usw2a ~/run_pytorch_test.sh`. | Dynamically booted `g4dn.xlarge` in `us-west-2a`, detected **Tesla T4**, PyTorch 2.14.1+cu130 matrix multiply passed. | **PASSED** |
| **Oregon Zone-C GPU (`us-west-2c`)** | Submitted `sbatch -p gpu-usw2c ~/run_pytorch_test.sh`. | Dynamically booted `g4dn.xlarge` in `us-west-2c`, detected **Tesla T4**, PyTorch 2.14.1+cu130 matrix multiply passed. | **PASSED** |
| **Ohio Zone-A GPU (`us-east-2a`)** | Submitted `sbatch -M sc26-east -p gpu-use2a ~/run_pytorch_test.sh` from `sc26-west`. | Dynamically booted `g4dn.xlarge` in `us-east-2a`, detected **Tesla T4**, wrote `/home/user<N>/pytorch_use2a_*.out` back to Oregon. | **PASSED** |
| **Federated Auto GPU Queue (`gpu*`)** | Submitted `sbatch -p gpu ~/run_pytorch_test.sh`. | Dynamically booted `g4dn.xlarge`, detected **Tesla T4**, completed with exit code `0:0`. | **PASSED** |
| **Open OnDemand 4.0.11 Portal** | Authenticated via HTTP Basic Auth to `/pun/sys/dashboard`. | `HTTP/1.1 200 OK`; PUN spawned cleanly; JupyterLab Batch Connect app configured for `gpu` partition. | **PASSED** |

---

## 6. Estimated Costs: Multi-Region T4 Test Cluster vs. SC25 GCP

*Prices are based on AWS On-Demand list pricing in `us-west-2` and `us-east-2`.*

### A. Current Multi-Region Federated GPU Test Cluster (`sc26-west` + `sc26-east`)

Because all GPU queues use **dynamic autoscaling (`MinCount: 0`)**, the `g4dn.xlarge` GPU nodes automatically power down after sitting idle (`scaledown_idletime = 10` minutes), dropping GPU compute cost to **\$0.00/hr** when no jobs are running.

| Resource | Region & AZ | Instance / Storage Type | Hourly Rate (USD) | Daily Cost (24 Hours) | Notes |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`sc26-west` Primary HeadNode** | `us-west-2a` | `m6i.4xlarge` (16 vCPU, 64 GiB RAM) | ~\$0.768 / hr | ~\$18.43 / day | Handles 100+ concurrent OOD + SSH users |
| **`sc26-east` Spoke HeadNode** | `us-east-2a` | `m6i.2xlarge` (8 vCPU, 32 GiB RAM) | ~\$0.384 / hr | ~\$9.22 / day | Federated sibling controller in Ohio |
| **GP3 NVMe EBS Volumes (220 GB total)** | Both Regions | `120 GB` (`us-west-2`) + `100 GB` (`us-east-2`) GP3 | ~\$0.024 / hr | ~\$0.59 / day | \$0.08 / GB-month (`3,000 IOPS`, `125 MB/s`) |
| **Amazon EFS (`/shared`, Elastic)** | Both Regions | Serverless EFS (`8.0 Exabytes` max, `<1 GB` used) | ~\$0.001 / hr | ~\$0.01 / day | \$0.30 / GB-month for actual bytes stored (vs. \$6.83/day fixed 1 TB Filestore on GCP!) |
| **4x Dynamic `g4dn.xlarge` (T4 GPU)** | `us-west-2a`, `2c`, `us-east-2a` | `g4dn.xlarge` (1x Tesla T4 GPU each) | **\$0.00 / hr (Idle)**<br/>*\$0.526 / hr per active node* | **\$0.00 / day (Idle)**<br/>*\$2.10 / hr when all 4 run* | Automatically scales to 0 after 10 min idle |
| **Total Federated Cluster (Idle Baseline)** | **Multi-Region** | **2 HeadNodes + Storage (0 Active GPUs)** | **~\$1.18 / hr** | **~\$28.25 / day** | **Ready 24/7; scales GPUs on demand** |

---

### B. GCP (`SC25`) vs. AWS (`SC26`) Architectural Mapping

| Capability | SC25 on GCP (`SC25_SUMMARY.md`) | SC26 on AWS (`nersc-sc26`) |
| :--- | :--- | :--- |
| **Cluster Orchestrator** | Google Cloud Cluster Toolkit (`ghpc`) + SchedMD Slurm GCP v6 | **AWS ParallelCluster v3.15.0** (`pcluster`) + Slurm 25.11.8 |
| **Multi-Region / Multi-AZ Support** | Single-region / single-zone (`us-central1-a`) | **Multi-Region Slurm Federation (`sc26-fed`)** across `us-west-2a`, `us-west-2c`, `us-east-2a` |
| **Login & OOD Node Sizing** | Separate Login + Controller (`2x n1-standard-4`, 4 vCPU / 15 GB each) | **Beefy Primary HeadNode (`m6i.4xlarge`, 16 vCPU / 64 GiB RAM)** + Spoke HeadNode (`m6i.2xlarge`) |
| **Shared Storage (`/shared`, `/home`, `/deploy`)** | Fixed 1 TB Google Cloud Filestore (~\$6.83/day fixed minimum cost) | **Elastic Amazon EFS (`/shared`, 8.0 EB max, ~\$0.01/day when idle) + HeadNode GP3 NVMe NFS (`/home` & `/deploy`, ~\$0.59/day)** |
| **Compute Node Provisioning** | Custom pre-baked image or startup script | Stock ParallelCluster AMI + **Slurm Prolog (`90_sc26_compute_setup.sh`)** + `OnNodeConfigured` |
| **Reserved GPU Attachment** | GCP DWS / Reservation | **AWS On-Demand Capacity Reservation (`CapacityReservationId: cr-xxxxx`)** |
