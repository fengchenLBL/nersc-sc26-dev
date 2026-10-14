#!/usr/bin/env bash
set -euo pipefail

# Sets up:
# 1. SSH keypair (sc26-key) in both us-west-2 and us-east-2 (~/.ssh/sc26-key.pem)
# 2. A non-overlapping VPC (10.2.0.0/16) and public subnet (10.2.1.0/24 in us-east-2a) in us-east-2
# 3. Inter-Region VPC Peering between us-west-2 VPC (172.31.0.0/16) and us-east-2 VPC (10.2.0.0/16)
# 4. Automatically populates Subnet IDs into config/sc26-test-gpu.yaml and config/sc26-east-gpu.yaml

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEST_REGION="us-west-2"
EAST_REGION="us-east-2"
KEY_NAME="sc26-key"
KEY_FILE="${HOME}/.ssh/sc26-key.pem"

echo "=== 1. Ensuring SSH KeyPair (${KEY_NAME}) Exists in ${WEST_REGION} and ${EAST_REGION} ==="
mkdir -p "${HOME}/.ssh"
if ! aws ec2 describe-key-pairs --region "${WEST_REGION}" --key-names "${KEY_NAME}" &>/dev/null; then
    aws ec2 create-key-pair \
        --region "${WEST_REGION}" \
        --key-name "${KEY_NAME}" \
        --query "KeyMaterial" \
        --output text > "${KEY_FILE}"
    chmod 400 "${KEY_FILE}"
    echo "Created ${KEY_NAME} in ${WEST_REGION} and saved to ${KEY_FILE}"
else
    echo "KeyPair ${KEY_NAME} already exists in ${WEST_REGION} (${KEY_FILE})"
fi

if ! aws ec2 describe-key-pairs --region "${EAST_REGION}" --key-names "${KEY_NAME}" &>/dev/null; then
    TMP_PUB="/tmp/sc26-key.pub"
    ssh-keygen -y -f "${KEY_FILE}" > "${TMP_PUB}"
    aws ec2 import-key-pair --region "${EAST_REGION}" --key-name "${KEY_NAME}" --public-key-material "fileb://${TMP_PUB}" >/dev/null
    rm -f "${TMP_PUB}"
    echo "Imported ${KEY_NAME} into ${EAST_REGION}"
else
    echo "KeyPair ${KEY_NAME} already exists in ${EAST_REGION}"
fi

echo "=== 2. Discovering ${WEST_REGION} VPC & Subnets (us-west-2a, us-west-2c) ==="
WEST_VPC_ID=$(aws ec2 describe-vpcs --region "${WEST_REGION}" --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text)
WEST_VPC_CIDR=$(aws ec2 describe-vpcs --region "${WEST_REGION}" --vpc-ids "${WEST_VPC_ID}" --query "Vpcs[0].CidrBlock" --output text)
USW2A_SUBNET_ID=$(aws ec2 describe-subnets --region "${WEST_REGION}" --filters "Name=vpc-id,Values=${WEST_VPC_ID}" "Name=availability-zone,Values=${WEST_REGION}a" --query "Subnets[0].SubnetId" --output text)
USW2C_SUBNET_ID=$(aws ec2 describe-subnets --region "${WEST_REGION}" --filters "Name=vpc-id,Values=${WEST_VPC_ID}" "Name=availability-zone,Values=${WEST_REGION}c" --query "Subnets[0].SubnetId" --output text)
echo "West VPC: ${WEST_VPC_ID} (${WEST_VPC_CIDR})"
echo "  - us-west-2a Subnet: ${USW2A_SUBNET_ID}"
echo "  - us-west-2c Subnet: ${USW2C_SUBNET_ID}"

echo "=== 3. Creating Non-Overlapping VPC (10.2.0.0/16) & Subnet in ${EAST_REGION}a ==="
EXISTING_EAST_VPC=$(aws ec2 describe-vpcs --region "${EAST_REGION}" --filters "Name=cidr,Values=10.2.0.0/16" "Name=tag:Name,Values=sc26-east-vpc" --query "Vpcs[0].VpcId" --output text)
if [ "${EXISTING_EAST_VPC}" != "None" ] && [ -n "${EXISTING_EAST_VPC}" ]; then
    EAST_VPC_ID="${EXISTING_EAST_VPC}"
    echo "Reusing existing East VPC: ${EAST_VPC_ID}"
else
    EAST_VPC_ID=$(aws ec2 create-vpc --region "${EAST_REGION}" --cidr-block "10.2.0.0/16" --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=sc26-east-vpc}]" --query "Vpc.VpcId" --output text)
    aws ec2 modify-vpc-attribute --region "${EAST_REGION}" --vpc-id "${EAST_VPC_ID}" --enable-dns-support "{\"Value\":true}"
    aws ec2 modify-vpc-attribute --region "${EAST_REGION}" --vpc-id "${EAST_VPC_ID}" --enable-dns-hostnames "{\"Value\":true}"
    echo "Created East VPC: ${EAST_VPC_ID} (10.2.0.0/16)"
fi

EXISTING_EAST_SUBNET=$(aws ec2 describe-subnets --region "${EAST_REGION}" --filters "Name=vpc-id,Values=${EAST_VPC_ID}" "Name=availability-zone,Values=${EAST_REGION}a" --query "Subnets[0].SubnetId" --output text)
if [ "${EXISTING_EAST_SUBNET}" != "None" ] && [ -n "${EXISTING_EAST_SUBNET}" ]; then
    EAST_SUBNET_ID="${EXISTING_EAST_SUBNET}"
    echo "Reusing existing East Subnet (${EAST_REGION}a): ${EAST_SUBNET_ID}"
else
    EAST_SUBNET_ID=$(aws ec2 create-subnet --region "${EAST_REGION}" --vpc-id "${EAST_VPC_ID}" --cidr-block "10.2.1.0/24" --availability-zone "${EAST_REGION}a" --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=sc26-east-2a-subnet}]" --query "Subnet.SubnetId" --output text)
    aws ec2 modify-subnet-attribute --region "${EAST_REGION}" --subnet-id "${EAST_SUBNET_ID}" --map-public-ip-on-launch
    echo "Created East Subnet (${EAST_REGION}a): ${EAST_SUBNET_ID} (10.2.1.0/24)"
fi

EXISTING_IGW=$(aws ec2 describe-internet-gateways --region "${EAST_REGION}" --filters "Name=attachment.vpc-id,Values=${EAST_VPC_ID}" --query "InternetGateways[0].InternetGatewayId" --output text)
if [ "${EXISTING_IGW}" == "None" ] || [ -z "${EXISTING_IGW}" ]; then
    IGW_ID=$(aws ec2 create-internet-gateway --region "${EAST_REGION}" --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=sc26-east-igw}]" --query "InternetGateway.InternetGatewayId" --output text)
    aws ec2 attach-internet-gateway --region "${EAST_REGION}" --vpc-id "${EAST_VPC_ID}" --internet-gateway-id "${IGW_ID}"
else
    IGW_ID="${EXISTING_IGW}"
fi

EAST_RTB_ID=$(aws ec2 describe-route-tables --region "${EAST_REGION}" --filters "Name=vpc-id,Values=${EAST_VPC_ID}" --query "RouteTables[0].RouteTableId" --output text)
aws ec2 create-route --region "${EAST_REGION}" --route-table-id "${EAST_RTB_ID}" --destination-cidr-block "0.0.0.0/0" --gateway-id "${IGW_ID}" >/dev/null 2>&1 || true

echo "=== 4. Establishing Inter-Region VPC Peering (${WEST_REGION} <-> ${EAST_REGION}) ==="
PEERING_ID=$(aws ec2 describe-vpc-peering-connections --region "${WEST_REGION}" \
    --filters "Name=requester-vpc-info.vpc-id,Values=${WEST_VPC_ID}" "Name=accepter-vpc-info.vpc-id,Values=${EAST_VPC_ID}" "Name=status-code,Values=pending-acceptance,provisioning,active" \
    --query "VpcPeeringConnections[0].VpcPeeringConnectionId" --output text)

if [ "${PEERING_ID}" == "None" ] || [ -z "${PEERING_ID}" ]; then
    PEERING_ID=$(aws ec2 create-vpc-peering-connection \
        --region "${WEST_REGION}" \
        --vpc-id "${WEST_VPC_ID}" \
        --peer-vpc-id "${EAST_VPC_ID}" \
        --peer-region "${EAST_REGION}" \
        --tag-specifications "ResourceType=vpc-peering-connection,Tags=[{Key=Name,Value=sc26-west-east-peering}]" \
        --query "VpcPeeringConnection.VpcPeeringConnectionId" --output text)
    echo "Created VPC Peering request: ${PEERING_ID}, waiting 5s to accept in ${EAST_REGION}..."
    sleep 5
fi

aws ec2 accept-vpc-peering-connection --region "${EAST_REGION}" --vpc-peering-connection-id "${PEERING_ID}" >/dev/null 2>&1 || true
echo "VPC Peering Active: ${PEERING_ID}"

# Add cross-region routes in both VPCs
WEST_RTB_IDS=$(aws ec2 describe-route-tables --region "${WEST_REGION}" --filters "Name=vpc-id,Values=${WEST_VPC_ID}" --query "RouteTables[].RouteTableId" --output text)
for rtb in ${WEST_RTB_IDS}; do
    aws ec2 create-route --region "${WEST_REGION}" --route-table-id "${rtb}" --destination-cidr-block "10.2.0.0/16" --vpc-peering-connection-id "${PEERING_ID}" >/dev/null 2>&1 || \
    aws ec2 replace-route --region "${WEST_REGION}" --route-table-id "${rtb}" --destination-cidr-block "10.2.0.0/16" --vpc-peering-connection-id "${PEERING_ID}" >/dev/null 2>&1 || true
done

aws ec2 create-route --region "${EAST_REGION}" --route-table-id "${EAST_RTB_ID}" --destination-cidr-block "${WEST_VPC_CIDR}" --vpc-peering-connection-id "${PEERING_ID}" >/dev/null 2>&1 || \
aws ec2 replace-route --region "${EAST_REGION}" --route-table-id "${EAST_RTB_ID}" --destination-cidr-block "${WEST_VPC_CIDR}" --vpc-peering-connection-id "${PEERING_ID}" >/dev/null 2>&1 || true

echo "=== 5. Populating Discovered Subnet IDs into config/*.yaml ==="
for cfg in "${SCRIPT_DIR}/config/sc26-test-gpu.yaml" "${SCRIPT_DIR}/config/sc26-east-gpu.yaml" "${SCRIPT_DIR}/config/sc26-test-cpu-quota5.yaml"; do
    if [ -f "${cfg}" ]; then
        sed -i.bak \
            -e "s|<REPLACE_WITH_USW2A_SUBNET_ID>|${USW2A_SUBNET_ID}|g" \
            -e "s|<REPLACE_WITH_USW2C_SUBNET_ID>|${USW2C_SUBNET_ID}|g" \
            -e "s|<REPLACE_WITH_USE2A_SUBNET_ID>|${EAST_SUBNET_ID}|g" \
            "${cfg}"
        rm -f "${cfg}.bak"
    fi
done

echo "=== Multi-Region Network & YAML Configs Ready! ==="
echo "WEST_VPC_ID=${WEST_VPC_ID} (${WEST_VPC_CIDR})"
echo "  USW2A_SUBNET_ID=${USW2A_SUBNET_ID}"
echo "  USW2C_SUBNET_ID=${USW2C_SUBNET_ID}"
echo "EAST_VPC_ID=${EAST_VPC_ID} (10.2.0.0/16)"
echo "  USE2A_SUBNET_ID=${EAST_SUBNET_ID}"
echo "PEERING_ID=${PEERING_ID}"
