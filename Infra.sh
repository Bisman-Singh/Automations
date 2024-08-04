#!/bin/bash

# Function to create IAM role and instance profile
create_iam_role() {
    ROLE_NAME="SSM_access"
    INSTANCE_PROFILE_NAME="SSM_access"
    TRUST_POLICY='{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": [
                    "sts:AssumeRole"
                ],
                "Principal": {
                    "Service": [
                        "ec2.amazonaws.com"
                    ]
                }
            }
        ]
    }'

    # Check if IAM role already exists
    ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --region "$REGION" --query 'Role.Arn' --output text 2>/dev/null)
    if [ -z "$ROLE_ARN" ]; then
        echo "Creating IAM Role: $ROLE_NAME"
        aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST_POLICY" --region "$REGION"
        aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore --region "$REGION"
    else
        echo "IAM Role $ROLE_NAME already exists"
    fi

    # Get Role ARN
    ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --region "$REGION" --query 'Role.Arn' --output text)
    echo "IAM Role ARN: $ROLE_ARN"

    # Check if Instance Profile already exists
    PROFILE_ARN=$(aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" --region "$REGION" --query 'InstanceProfile.Arn' --output text 2>/dev/null)
    if [ -z "$PROFILE_ARN" ]; then
        echo "Creating Instance Profile: $INSTANCE_PROFILE_NAME"
        aws iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" --region "$REGION"
        aws iam add-role-to-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" --role-name "$ROLE_NAME" --region "$REGION"
    else
        echo "Instance Profile $INSTANCE_PROFILE_NAME already exists"
    fi

    # Get Instance Profile ARN
    PROFILE_ARN=$(aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" --region "$REGION" --query 'InstanceProfile.Arn' --output text)
    echo "Instance Profile ARN: $PROFILE_ARN"
}

# Variables
echo "Enter AWS region (e.g., us-west-1):"
read REGION
echo "Enter VPC CIDR block (e.g., 10.0.0.0/16):"
read VPC_CIDR
echo "Enter Public Subnet CIDR block (e.g., 10.0.1.0/24):"
read PUBLIC_SUBNET_CIDR
echo "Enter Private Subnet CIDR block (e.g., 10.0.2.0/24):"
read PRIVATE_SUBNET_CIDR
echo "Enter AMI ID for Frontend instance:"
read FRONTEND_AMI
echo "Enter AMI ID for Backend instance:"
read BACKEND_AMI
echo "Enter Instance Type for Frontend instance (e.g., t2.micro):"
read FRONTEND_TYPE
echo "Enter Instance Type for Backend instance (e.g., t2.micro):"
read BACKEND_TYPE

# Function to create VPC
create_vpc() {
    echo "Creating VPC with CIDR $VPC_CIDR"
    VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" --region "$REGION" --query 'Vpc.VpcId' --output text)
    if [ -z "$VPC_ID" ]; then
        echo "Failed to create VPC"
        exit 1
    fi
    aws ec2 create-tags --resources "$VPC_ID" --tags Key=Name,Value=Automated_VPC --region "$REGION"
    echo "VPC created with ID: $VPC_ID"
}

# Function to create subnets
create_subnets() {
    echo "Creating Subnets"
    PUBLIC_SUBNET_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PUBLIC_SUBNET_CIDR" --region "$REGION" --query 'Subnet.SubnetId' --output text)
    PRIVATE_SUBNET_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PRIVATE_SUBNET_CIDR" --region "$REGION" --query 'Subnet.SubnetId' --output text)

    if [ -z "$PUBLIC_SUBNET_ID" ] || [ -z "$PRIVATE_SUBNET_ID" ]; then
        echo "Failed to create subnets"
        exit 1
    fi

    aws ec2 create-tags --resources "$PUBLIC_SUBNET_ID" --tags Key=Name,Value=Public --region "$REGION"
    aws ec2 create-tags --resources "$PRIVATE_SUBNET_ID" --tags Key=Name,Value=Private --region "$REGION"

    echo "Public Subnet ID: $PUBLIC_SUBNET_ID"
    echo "Private Subnet ID: $PRIVATE_SUBNET_ID"
}

# Function to create and attach internet gateway
create_internet_gateway() {
    echo "Creating Internet Gateway"
    IGW_ID=$(aws ec2 create-internet-gateway --region "$REGION" --query 'InternetGateway.InternetGatewayId' --output text)
    if [ -z "$IGW_ID" ]; then
        echo "Failed to create Internet Gateway"
        exit 1
    fi

    aws ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID" --region "$REGION"
    aws ec2 create-tags --resources "$IGW_ID" --tags Key=Name,Value=Automated_IGW --region "$REGION"
    echo "Internet Gateway ID: $IGW_ID attached to VPC."
}

# Function to allocate Elastic IP and create NAT Gateway
create_nat_gateway() {
    echo "Checking for available Elastic IP"
    ALLOC_ID=$(aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].AllocationId' --output text --region "$REGION")
    
    if [ -z "$ALLOC_ID" ]; then
        echo "No available Elastic IP. Allocating a new one."
        ALLOC_ID=$(aws ec2 allocate-address --query 'AllocationId' --output text --region "$REGION")
    else
        echo "Reusing existing Elastic IP"
    fi

    echo "Creating NAT Gateway with Elastic IP"
    NAT_GW_ID=$(aws ec2 create-nat-gateway --subnet-id "$PUBLIC_SUBNET_ID" --allocation-id "$ALLOC_ID" --region "$REGION" --query 'NatGateway.NatGatewayId' --output text)
    if [ -z "$NAT_GW_ID" ]; then
        echo "Failed to create NAT Gateway"
        exit 1
    fi

    aws ec2 create-tags --resources "$NAT_GW_ID" --tags Key=Name,Value=Automated_NAT --region "$REGION"
    echo "NAT Gateway ID: $NAT_GW_ID"
}

# Function to create and associate route tables
create_route_tables() {
    echo "Creating and associating route tables"
    PUBLIC_ROUTE_TABLE_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --region "$REGION" --query 'RouteTable.RouteTableId' --output text)
    PRIVATE_ROUTE_TABLE_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --region "$REGION" --query 'RouteTable.RouteTableId' --output text)

    if [ -z "$PUBLIC_ROUTE_TABLE_ID" ] || [ -z "$PRIVATE_ROUTE_TABLE_ID" ]; then
        echo "Failed to create route tables"
        exit 1
    fi

    aws ec2 create-route --route-table-id "$PUBLIC_ROUTE_TABLE_ID" --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID" --region "$REGION"
    aws ec2 create-route --route-table-id "$PRIVATE_ROUTE_TABLE_ID" --destination-cidr-block "0.0.0.0/0" --nat-gateway-id "$NAT_GW_ID" --region "$REGION"

    aws ec2 associate-route-table --route-table-id "$PUBLIC_ROUTE_TABLE_ID" --subnet-id "$PUBLIC_SUBNET_ID" --region "$REGION"
    aws ec2 associate-route-table --route-table-id "$PRIVATE_ROUTE_TABLE_ID" --subnet-id "$PRIVATE_SUBNET_ID" --region "$REGION"

    aws ec2 create-tags --resources "$PUBLIC_ROUTE_TABLE_ID" --tags Key=Name,Value=Public_RT --region "$REGION"
    aws ec2 create-tags --resources "$PRIVATE_ROUTE_TABLE_ID" --tags Key=Name,Value=Private_RT --region "$REGION"
}

# Function to create security groups
create_security_groups() {
    echo "Creating Security Groups"
    FRONTEND_SG_ID=$(aws ec2 create-security-group --group-name frontend-sg --description "Frontend security group" --vpc-id "$VPC_ID" --region "$REGION" --query 'GroupId' --output text)
    BACKEND_SG_ID=$(aws ec2 create-security-group --group-name backend-sg --description "Backend security group" --vpc-id "$VPC_ID" --region "$REGION" --query 'GroupId' --output text)

    if [ -z "$FRONTEND_SG_ID" ] || [ -z "$BACKEND_SG_ID" ]; then
        echo "Failed to create security groups"
        exit 1
    fi

    aws ec2 authorize-security-group-ingress --group-id "$FRONTEND_SG_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0 --region "$REGION"
    aws ec2 authorize-security-group-ingress --group-id "$FRONTEND_SG_ID" --protocol tcp --port 443 --cidr 0.0.0.0/0 --region "$REGION"
    aws ec2 authorize-security-group-ingress --group-id "$BACKEND_SG_ID" --protocol tcp --port 3306 --source-group "$FRONTEND_SG_ID" --region "$REGION"

    aws ec2 create-tags --resources "$FRONTEND_SG_ID" --tags Key=Name,Value="Frontend SG" --region "$REGION"
    aws ec2 create-tags --resources "$BACKEND_SG_ID" --tags Key=Name,Value="Backend SG" --region "$REGION"
}

# Function to launch instances
launch_instances() {
    echo "Launching Frontend instance in Public Subnet"
    FRONTEND_INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$FRONTEND_AMI" \
        --instance-type "$FRONTEND_TYPE" \
        --subnet-id "$PUBLIC_SUBNET_ID" \
        --associate-public-ip-address \
        --iam-instance-profile Name=SSM_access \
        --security-group-ids "$FRONTEND_SG_ID" \
        --region "$REGION" \
        --query 'Instances[0].InstanceId' \
        --output text \
        --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=Frontend}]')

    echo "Launching Backend instance in Private Subnet"
    BACKEND_INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$BACKEND_AMI" \
        --instance-type "$BACKEND_TYPE" \
        --subnet-id "$PRIVATE_SUBNET_ID" \
        --iam-instance-profile Name=SSM_access \
        --security-group-ids "$BACKEND_SG_ID" \
        --region "$REGION" \
        --query 'Instances[0].InstanceId' \
        --output text \
        --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=Backend}]')

    if [ -z "$FRONTEND_INSTANCE_ID" ] || [ -z "$BACKEND_INSTANCE_ID" ]; then
        echo "Failed to launch instances"
        exit 1
    fi

    echo "Frontend instance launched with ID: $FRONTEND_INSTANCE_ID"
    echo "Backend instance launched with ID: $BACKEND_INSTANCE_ID"

    # Save the instance IDs to a file for the next script
    echo "Frontend_Instance_ID=$FRONTEND_INSTANCE_ID" > instance_ids.txt
    echo "Backend_Instance_ID=$BACKEND_INSTANCE_ID" >> instance_ids.txt
}

# Main script execution
create_iam_role
create_vpc
create_subnets
create_internet_gateway
create_nat_gateway
create_route_tables
create_security_groups
launch_instances

echo "Setup complete."
