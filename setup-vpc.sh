#!/bin/bash
# VPC Setup Script for SmartTrip Infrastructure
# Creates VPC, subnets, internet gateway, and route tables

set -e

# Source configuration and utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"

# Resource ID storage
RESOURCE_IDS_FILE="$SCRIPT_DIR/resource-ids.txt"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - VPC Setup - $1" | tee -a "$SCRIPT_DIR/infrastructure-setup.log"
}

# Error handling
error_exit() {
    echo "ERROR: $1" | tee -a "$SCRIPT_DIR/infrastructure-setup.log"
    exit 1
}

# Success message
success() {
    echo "SUCCESS: $1" | tee -a "$SCRIPT_DIR/infrastructure-setup.log"
}

# Create VPC
create_vpc() {
    log "Creating VPC..."
    
    local vpc_cidr=$(jq -r '.vpc.cidr' "$CONFIG_FILE")
    local project_name=$(jq -r '.project.name' "$CONFIG_FILE")
    
    local vpc_id=$(aws ec2 create-vpc \
        --cidr-block "$vpc_cidr" \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$project_name-vpc},{Key=Project,Value=$project_name}]" \
        --query 'Vpc.VpcId' \
        --output text 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$vpc_id" ]; then
        error_exit "Failed to create VPC"
    fi
    
    echo "VPC_ID=$vpc_id" >> "$RESOURCE_IDS_FILE"
    success "VPC created: $vpc_id"
    
    # Wait for VPC to be available
    log "Waiting for VPC to become available..."
    aws ec2 wait vpc-available --vpc-ids "$vpc_id"
}

# Create Internet Gateway
create_internet_gateway() {
    log "Creating Internet Gateway..."
    
    local project_name=$(jq -r '.project.name' "$CONFIG_FILE")
    local vpc_id=$(grep "VPC_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    
    local igw_id=$(aws ec2 create-internet-gateway \
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$project_name-igw},{Key=Project,Value=$project_name}]" \
        --query 'InternetGateway.InternetGatewayId' \
        --output text 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$igw_id" ]; then
        error_exit "Failed to create Internet Gateway"
    fi
    
    echo "IGW_ID=$igw_id" >> "$RESOURCE_IDS_FILE"
    success "Internet Gateway created: $igw_id"
    
    # Attach Internet Gateway to VPC
    log "Attaching Internet Gateway to VPC..."
    aws ec2 attach-internet-gateway \
        --internet-gateway-id "$igw_id" \
        --vpc-id "$vpc_id" || error_exit "Failed to attach Internet Gateway"
    
    success "Internet Gateway attached to VPC"
}

# Create Public Subnets
create_public_subnets() {
    log "Creating public subnets..."
    
    local project_name=$(jq -r '.project.name' "$CONFIG_FILE")
    local vpc_id=$(grep "VPC_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local igw_id=$(grep "IGW_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    
    # Read subnets from config
    local subnet_count=$(jq '.vpc.public_subnets | length' "$CONFIG_FILE")
    
    for ((i=0; i<subnet_count; i++)); do
        local subnet_cidr=$(jq -r ".vpc.public_subnets[$i].cidr" "$CONFIG_FILE")
        local subnet_az=$(jq -r ".vpc.public_subnets[$i].availability_zone" "$CONFIG_FILE")
        local subnet_name=$(jq -r ".vpc.public_subnets[$i].name" "$CONFIG_FILE")
        
        log "Creating subnet $subnet_name in $subnet_az..."
        
        local subnet_id=$(aws ec2 create-subnet \
            --vpc-id "$vpc_id" \
            --cidr-block "$subnet_cidr" \
            --availability-zone "$subnet_az" \
            --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$project_name-$subnet_name},{Key=Project,Value=$project_name}]" \
            --query 'Subnet.SubnetId' \
            --output text 2>/dev/null)
        
        if [ $? -ne 0 ] || [ -z "$subnet_id" ]; then
            error_exit "Failed to create subnet $subnet_name"
        fi
        
        echo "SUBNET_${i}_ID=$subnet_id" >> "$RESOURCE_IDS_FILE"
        echo "SUBNET_${i}_NAME=$subnet_name" >> "$RESOURCE_IDS_FILE"
        success "Subnet $subnet_name created: $subnet_id"
        
        # Wait for subnet to be available
        aws ec2 wait subnet-available --subnet-ids "$subnet_id"
        
        # Modify subnet to auto-assign public IP
        aws ec2 modify-subnet-attribute \
            --subnet-id "$subnet_id" \
            --map-public-ip-on-launch
    done
}

# Create Route Tables
create_route_tables() {
    log "Creating route tables..."
    
    local project_name=$(jq -r '.project.name' "$CONFIG_FILE")
    local vpc_id=$(grep "VPC_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local igw_id=$(grep "IGW_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    
    # Create main route table
    local rtb_id=$(aws ec2 create-route-table \
        --vpc-id "$vpc_id" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$project_name-rtb},{Key=Project,Value=$project_name}]" \
        --query 'RouteTable.RouteTableId' \
        --output text 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$rtb_id" ]; then
        error_exit "Failed to create route table"
    fi
    
    echo "RTB_ID=$rtb_id" >> "$RESOURCE_IDS_FILE"
    success "Route table created: $rtb_id"
    
    # Add route to Internet Gateway
    log "Adding route to Internet Gateway..."
    aws ec2 create-route \
        --route-table-id "$rtb_id" \
        --destination-cidr-block "0.0.0.0/0" \
        --gateway-id "$igw_id" || error_exit "Failed to create route to Internet Gateway"
    
    # Associate route table with all public subnets
    local subnet_count=$(jq '.vpc.public_subnets | length' "$CONFIG_FILE")
    
    for ((i=0; i<subnet_count; i++)); do
        local subnet_id=$(grep "SUBNET_${i}_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
        local subnet_name=$(grep "SUBNET_${i}_NAME=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
        
        log "Associating route table with subnet $subnet_name..."
        
        local association_id=$(aws ec2 associate-route-table \
            --route-table-id "$rtb_id" \
            --subnet-id "$subnet_id" \
            --query 'AssociationId' \
            --output text 2>/dev/null)
        
        if [ $? -ne 0 ] || [ -z "$association_id" ]; then
            error_exit "Failed to associate route table with subnet $subnet_name"
        fi
        
        echo "RT_ASSOC_${i}_ID=$association_id" >> "$RESOURCE_IDS_FILE"
        success "Route table associated with subnet $subnet_name"
    done
}

# Main execution
main() {
    log "Starting VPC setup..."
    
    # Initialize resource IDs file
    > "$RESOURCE_IDS_FILE"
    
    create_vpc
    create_internet_gateway
    create_public_subnets
    create_route_tables
    
    success "VPC setup completed successfully!"
    
    # Display created resources
    echo "=========================================="
    echo "VPC Resources Created:"
    echo "=========================================="
    cat "$RESOURCE_IDS_FILE"
    echo "=========================================="
}

# Execute main function
main "$@"
