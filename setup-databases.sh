#!/bin/bash
# Database Setup Script for SmartTrip Infrastructure
# Creates RDS PostgreSQL instances for backend and AI services

set -e

# Source configuration and utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"

# Resource ID storage
RESOURCE_IDS_FILE="$SCRIPT_DIR/resource-ids.txt"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Database Setup - $1" | tee -a "$SCRIPT_DIR/infrastructure-setup.log" >&2
}

# Error handling
error_exit() {
    echo "ERROR: $1" | tee -a "$SCRIPT_DIR/infrastructure-setup.log" >&2
    exit 1
}

# Success message
success() {
    echo "SUCCESS: $1" | tee -a "$SCRIPT_DIR/infrastructure-setup.log" >&2
}

# Warning message
warning() {
    echo "WARNING: $1" | tee -a "$SCRIPT_DIR/infrastructure-setup.log" >&2
}

# Get VPC ID and subnet IDs
get_network_info() {
    local vpc_id=$(grep "VPC_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local database_sg_id=$(grep "DATABASE_SG_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    
    if [ -z "$vpc_id" ]; then
        error_exit "VPC ID not found. Please run setup-vpc.sh first."
    fi
    
    if [ -z "$database_sg_id" ]; then
        error_exit "Database security group ID not found. Please run setup-security.sh first."
    fi
    
    echo "$vpc_id $database_sg_id"
}

# Create DB Subnet Group
create_db_subnet_group() {
    log "Creating DB subnet group..."
    
    local project_name=$(jq -r '.project.name' "$CONFIG_FILE")
    local subnet_group_name="${project_name}-db-subnet-group"
    
    # Get subnet IDs
    local subnet_count=$(jq '.vpc.public_subnets | length' "$CONFIG_FILE")
    local subnet_ids=()
    
    for ((i=0; i<subnet_count; i++)); do
        local subnet_id=$(grep "SUBNET_${i}_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
        subnet_ids+=("$subnet_id")
        # Debug: Check subnet details
        echo "DEBUG: Subnet $i ID: $subnet_id" | tee -a "$SCRIPT_DIR/infrastructure-setup.log"
        local subnet_az=$(aws ec2 describe-subnets --subnet-ids "$subnet_id" --query 'Subnets[0].AvailabilityZone' --output text 2>/dev/null)
        echo "DEBUG: Subnet $i AZ: $subnet_az" | tee -a "$SCRIPT_DIR/infrastructure-setup.log"
    done
    
    # Check if DB subnet group already exists and validate it
    local existing_subnet_group=$(aws rds describe-db-subnet-groups \
        --db-subnet-group-name "$subnet_group_name" \
        --query 'DBSubnetGroups[0].DBSubnetGroupName' \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$existing_subnet_group" ] && [ "$existing_subnet_group" != "None" ]; then
        # Check if existing subnet group uses correct subnets
        local existing_subnets=$(aws rds describe-db-subnet-groups \
            --db-subnet-group-name "$subnet_group_name" \
            --query 'DBSubnetGroups[0].Subnets[].SubnetIdentifier' \
            --output text 2>/dev/null || echo "")
        
        echo "DEBUG: Existing subnet group found: $existing_subnet_group" | tee -a "$SCRIPT_DIR/infrastructure-setup.log"
        echo "DEBUG: Existing subnets: $existing_subnets" | tee -a "$SCRIPT_DIR/infrastructure-setup.log"
        echo "DEBUG: Required subnets: ${subnet_ids[*]}" | tee -a "$SCRIPT_DIR/infrastructure-setup.log"
        
        # Check if existing subnets match our required subnets
        local subnet_match=true
        for required_subnet in "${subnet_ids[@]}"; do
            if ! echo "$existing_subnets" | grep -q "$required_subnet"; then
                subnet_match=false
                break
            fi
        done
        
        if [ "$subnet_match" = true ]; then
            success "DB subnet group already exists with correct subnets: $subnet_group_name"
        else
            echo "Updating DB subnet group to use correct subnets..." | tee -a "$SCRIPT_DIR/infrastructure-setup.log"
            # Delete and recreate subnet group with correct subnets
            aws rds delete-db-subnet-group \
                --db-subnet-group-name "$subnet_group_name" || echo "Failed to delete existing subnet group"
            
            # Create DB subnet group with correct subnets
            echo "Creating DB subnet group with subnets: ${subnet_ids[*]}" | tee -a "$SCRIPT_DIR/infrastructure-setup.log"
            aws rds create-db-subnet-group \
                --db-subnet-group-name "$subnet_group_name" \
                --db-subnet-group-description "Subnet group for SmartTrip databases" \
                --subnet-ids "${subnet_ids[@]}" || error_exit "Failed to create DB subnet group"
            
            success "DB subnet group recreated: $subnet_group_name"
        fi
    else
        # Create new DB subnet group
        echo "Creating new DB subnet group with subnets: ${subnet_ids[*]}" | tee -a "$SCRIPT_DIR/infrastructure-setup.log"
        aws rds create-db-subnet-group \
            --db-subnet-group-name "$subnet_group_name" \
            --db-subnet-group-description "Subnet group for SmartTrip databases" \
            --subnet-ids "${subnet_ids[@]}" || error_exit "Failed to create DB subnet group"
        
        success "DB subnet group created: $subnet_group_name"
    fi
    
    echo "DB_SUBNET_GROUP_NAME=$subnet_group_name" >> "$RESOURCE_IDS_FILE"
}

# Create RDS Instance
create_rds_instance() {
    local db_config="$1"
    local db_key="$2"
    
    local identifier=$(echo "$db_config" | jq -r '.identifier')
    local instance_class=$(echo "$db_config" | jq -r '.instance_class')
    local engine=$(echo "$db_config" | jq -r '.engine')
    local engine_version=$(echo "$db_config" | jq -r '.engine_version')
    local storage=$(echo "$db_config" | jq -r '.storage')
    local storage_type=$(echo "$db_config" | jq -r '.storage_type')
    local username=$(echo "$db_config" | jq -r '.username')
    local password=$(echo "$db_config" | jq -r '.password')
    local backup_retention=$(echo "$db_config" | jq -r '.backup_retention')
    
    local project_name=$(jq -r '.project.name' "$CONFIG_FILE")
    local db_subnet_group_name=$(grep "DB_SUBNET_GROUP_NAME=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local database_sg_id=$(grep "DATABASE_SG_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    
    log "Creating RDS instance: $identifier"
    
    # Check if instance already exists
    local existing_instance=$(aws rds describe-db-instances \
        --db-instance-identifier "$identifier" \
        --query 'DBInstances[0].DBInstanceStatus' \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$existing_instance" ]; then
        warning "RDS instance $identifier already exists with status: $existing_instance"
        echo "$db_key=$identifier" >> "$RESOURCE_IDS_FILE"
        return 0
    fi
    
    # Create RDS instance
    aws rds create-db-instance \
        --db-instance-identifier "$identifier" \
        --db-instance-class "$instance_class" \
        --engine "$engine" \
        --engine-version "$engine_version" \
        --allocated-storage "$storage" \
        --storage-type "$storage_type" \
        --master-username "$username" \
        --master-user-password "$password" \
        --db-subnet-group-name "$db_subnet_group_name" \
        --vpc-security-group-ids "$database_sg_id" \
        --backup-retention-period "$backup_retention" \
        --no-multi-az \
        --no-publicly-accessible \
        --no-storage-encrypted \
        --no-deletion-protection \
        --tags Key=Name,Value="$project_name-$identifier" Key=Project,Value="$project_name" || error_exit "Failed to create RDS instance: $identifier"
    
    echo "$db_key=$identifier" >> "$RESOURCE_IDS_FILE"
    success "RDS instance creation initiated: $identifier"
    
    # Wait for instance to become available
    log "Waiting for RDS instance $identifier to become available..."
    aws rds wait db-instance-available --db-instance-identifier "$identifier"
    
    success "RDS instance $identifier is now available"
}

# Get Database Connection Information
get_database_info() {
    local identifier="$1"
    
    log "Retrieving connection information for $identifier"
    
    local endpoint=$(aws rds describe-db-instances \
        --db-instance-identifier "$identifier" \
        --query 'DBInstances[0].Endpoint.Address' \
        --output text 2>/dev/null)
    
    local port=$(aws rds describe-db-instances \
        --db-instance-identifier "$identifier" \
        --query 'DBInstances[0].Endpoint.Port' \
        --output text 2>/dev/null)
    
    local status=$(aws rds describe-db-instances \
        --db-instance-identifier "$identifier" \
        --query 'DBInstances[0].DBInstanceStatus' \
        --output text 2>/dev/null)
    
    echo "Database: $identifier"
    echo "Endpoint: $endpoint"
    echo "Port: $port"
    echo "Status: $status"
    echo "---"
    
    # Save connection info to file
    echo "${identifier}_ENDPOINT=$endpoint" >> "$RESOURCE_IDS_FILE"
    echo "${identifier}_PORT=$port" >> "$RESOURCE_IDS_FILE"
}

# Create Database Subnet Group and Instances
setup_databases() {
    log "Setting up databases..."
    
    # Get network info
    local network_info=($(get_network_info))
    local vpc_id="${network_info[0]}"
    local database_sg_id="${network_info[1]}"
    
    # Create DB subnet group
    create_db_subnet_group
    
    # Get database configurations
    local backend_db_config=$(jq '.database.backend' "$CONFIG_FILE")
    local ai_db_config=$(jq '.database.ai_service' "$CONFIG_FILE")
    
    # Launch both databases in parallel
    log "Launching both RDS instances in parallel..."
    
    # Start backend database creation in background
    (
        log "Starting backend database creation..."
        create_rds_instance "$backend_db_config" "BACKEND_DB_ID"
        echo "BACKEND_DB_COMPLETED" > "$SCRIPT_DIR/backend_db_status.tmp"
    ) &
    local backend_pid=$!
    
    # Start AI service database creation in background
    (
        log "Starting AI service database creation..."
        create_rds_instance "$ai_db_config" "AI_SERVICE_DB_ID"
        echo "AI_SERVICE_DB_COMPLETED" > "$SCRIPT_DIR/ai_service_db_status.tmp"
    ) &
    local ai_service_pid=$!
    
    # Wait for both databases to complete
    log "Waiting for both databases to complete creation..."
    wait $backend_pid
    local backend_exit_code=$?
    wait $ai_service_pid
    local ai_service_exit_code=$?
    
    # Clean up temporary files
    rm -f "$SCRIPT_DIR/backend_db_status.tmp" "$SCRIPT_DIR/ai_service_db_status.tmp"
    
    # Check if both databases were created successfully
    if [ $backend_exit_code -eq 0 ] && [ $ai_service_exit_code -eq 0 ]; then
        success "Both databases created successfully in parallel"
    else
        error_exit "One or more database creation failed"
    fi
}

# Validate Database Setup
validate_databases() {
    log "Validating database setup..."
    
    local backend_db_id=$(grep "BACKEND_DB_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local ai_service_db_id=$(grep "AI_SERVICE_DB_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    
    # Check backend database
    local backend_status=$(aws rds describe-db-instances \
        --db-instance-identifier "$backend_db_id" \
        --query 'DBInstances[0].DBInstanceStatus' \
        --output text 2>/dev/null)
    
    if [ "$backend_status" = "available" ]; then
        success "Backend database is available: $backend_db_id"
        get_database_info "$backend_db_id"
    else
        warning "Backend database status: $backend_status"
    fi
    
    # Check AI service database
    local ai_status=$(aws rds describe-db-instances \
        --db-instance-identifier "$ai_service_db_id" \
        --query 'DBInstances[0].DBInstanceStatus' \
        --output text 2>/dev/null)
    
    if [ "$ai_status" = "available" ]; then
        success "AI service database is available: $ai_service_db_id"
        get_database_info "$ai_service_db_id"
    else
        warning "AI service database status: $ai_status"
    fi
}

# Main execution
main() {
    log "Starting database setup..."
    
    # Check if resource IDs file exists
    if [ ! -f "$RESOURCE_IDS_FILE" ]; then
        error_exit "Resource IDs file not found. Please run setup-vpc.sh and setup-security.sh first."
    fi
    
    setup_databases
    validate_databases
    
    success "Database setup completed successfully!"
    
    # Display created resources
    echo "=========================================="
    echo "Database Resources Created:"
    echo "=========================================="
    grep -E "(DB_ID|_ENDPOINT|_PORT)" "$RESOURCE_IDS_FILE"
    echo "=========================================="
    
    echo "Database Connection Information:"
    echo "Backend DB: $(grep "BACKEND_DB_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)"
    echo "AI Service DB: $(grep "AI_SERVICE_DB_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)"
    echo "=========================================="
}

# Execute main function
main "$@"
