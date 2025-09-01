#!/usr/bin/env bash
set -euo pipefail

# ==== SỬA CÁC BIẾN NÀY ====
REGION="ap-southeast-1"
VPC_ID="vpc-0f21a566eac6f5ebc"
AZ1="${REGION}a"
AZ2="${REGION}b"
PRIVATE1_CIDR="10.0.1.0/24"
PRIVATE2_CIDR="10.0.2.0/24"
PUBLIC_SUBNET_FOR_NAT="subnet-0800603a593d587b2"   # 1 public subnet có Internet Gateway
CLUSTER_NAME="demo-eks"
# ==========================

echo "Creating private subnets..."
SUBNET1_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" \
  --cidr-block "$PRIVATE1_CIDR" --availability-zone "$AZ1" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=eks-private-1}]" \
  --query 'Subnet.SubnetId' --output text --region "$REGION")

SUBNET2_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" \
  --cidr-block "$PRIVATE2_CIDR" --availability-zone "$AZ2" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=eks-private-2}]" \
  --query 'Subnet.SubnetId' --output text --region "$REGION")

# Đảm bảo không tự cấp public IP
aws ec2 modify-subnet-attribute --subnet-id "$SUBNET1_ID" --no-map-public-ip-on-launch --region "$REGION"
aws ec2 modify-subnet-attribute --subnet-id "$SUBNET2_ID" --no-map-public-ip-on-launch --region "$REGION"

# Tag cho EKS
aws ec2 create-tags --resources "$SUBNET1_ID" "$SUBNET2_ID" --region "$REGION" --tags \
  Key="kubernetes.io/role/internal-elb",Value="1" \
  Key="kubernetes.io/cluster/$CLUSTER_NAME",Value="shared"

echo "Allocating EIP and creating NAT Gateway in $PUBLIC_SUBNET_FOR_NAT ..."
ALLOCATION_ID=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text --region "$REGION")

NAT_GW_ID=$(aws ec2 create-nat-gateway \
  --subnet-id "$PUBLIC_SUBNET_FOR_NAT" \
  --allocation-id "$ALLOCATION_ID" \
  --query 'NatGateway.NatGatewayId' --output text --region "$REGION")

echo "Waiting for NAT Gateway to become available..."
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW_ID" --region "$REGION"

# Route table cho private
RTB_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
  --query 'RouteTable.RouteTableId' --output text --region "$REGION")

aws ec2 create-tags --resources "$RTB_ID" --region "$REGION" --tags Key=Name,Value=eks-private-rt

aws ec2 create-route --route-table-id "$RTB_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id "$NAT_GW_ID" --region "$REGION"

aws ec2 associate-route-table --subnet-id "$SUBNET1_ID" --route-table-id "$RTB_ID" --region "$REGION"
aws ec2 associate-route-table --subnet-id "$SUBNET2_ID" --route-table-id "$RTB_ID" --region "$REGION"

CSV="${SUBNET1_ID},${SUBNET2_ID}"
echo "✅ PRIVATE_SUBNET_IDS_CSV=$CSV"
