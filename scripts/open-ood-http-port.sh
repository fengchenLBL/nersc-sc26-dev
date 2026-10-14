#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${1:-sc26-test}"
REGION="${2:-us-west-2}"

echo "=== Opening TCP Ports 80 & 443 on HeadNode Security Group for Cluster: ${CLUSTER_NAME} (${REGION}) ==="

HEAD_INSTANCE_ID=$(aws ec2 describe-instances \
    --region "${REGION}" \
    --filters "Name=tag:parallelcluster:cluster-name,Values=${CLUSTER_NAME}" \
              "Name=tag:parallelcluster:node-type,Values=HeadNode" \
              "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)

if [ -z "${HEAD_INSTANCE_ID}" ] || [ "${HEAD_INSTANCE_ID}" = "None" ]; then
    echo "ERROR: Could not find running HeadNode for cluster '${CLUSTER_NAME}' in ${REGION}."
    exit 1
fi

SG_ID=$(aws ec2 describe-instances \
    --region "${REGION}" \
    --instance-ids "${HEAD_INSTANCE_ID}" \
    --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" \
    --output text)

PUBLIC_IP=$(aws ec2 describe-instances \
    --region "${REGION}" \
    --instance-ids "${HEAD_INSTANCE_ID}" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text)

echo "HeadNode Instance: ${HEAD_INSTANCE_ID}"
echo "Security Group:    ${SG_ID}"
echo "Public IP:         ${PUBLIC_IP}"

aws ec2 authorize-security-group-ingress \
    --region "${REGION}" \
    --group-id "${SG_ID}" \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 2>/dev/null || echo "Port 80 already open on ${SG_ID}"

aws ec2 authorize-security-group-ingress \
    --region "${REGION}" \
    --group-id "${SG_ID}" \
    --protocol tcp --port 443 --cidr 0.0.0.0/0 2>/dev/null || echo "Port 443 already open on ${SG_ID}"

echo "=== ✓ Open OnDemand URL: http://${PUBLIC_IP}/ ==="
