#!/bin/bash
# Security Setup Script for SmartTrip Infrastructure
# Creates security groups, IAM roles, and security policies

set -e

# Source configuration and utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"

# Resource ID storage
RESOURCE_IDS_FILE="$SCRIPT_DIR/resource-ids.txt"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Security Setup - $1" | tee -a "$SCRIPT_DIR/infrastructure-setup.log" >&2
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

warning() {
    echo "WARNING: $1" | tee -a "$SCRIPT_DIR/infrastructure-setup.log" >&2
}

# Get VPC ID
get_vpc_id() {
    grep "VPC_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2
}

# Create Security Group
create_security_group() {
    local sg_name="$1"
    local sg_description="$2"
    local sg_key="$3"
    
    log "Creating security group: $sg_name"
    
    local vpc_id=$(get_vpc_id)
    local project_name=$(jq -r '.project.name' "$CONFIG_FILE")
    
    local sg_id=$(aws ec2 create-security-group \
        --group-name "$sg_name" \
        --description "$sg_description" \
        --vpc-id "$vpc_id" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$sg_name},{Key=Project,Value=$project_name}]" \
        --query 'GroupId' \
        --output text 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$sg_id" ]; then
        error_exit "Failed to create security group: $sg_name"
    fi
    
    echo "$sg_key=$sg_id" >> "$RESOURCE_IDS_FILE"
    success "Security group $sg_name created: $sg_id"
    
    echo "$sg_id"
}

# Add Security Group Rules
add_security_group_rules() {
    local sg_id="$1"
    local sg_rules="$2"
    
    echo "DEBUG: sg_id value: '$sg_id'" | tee -a "$SCRIPT_DIR/infrastructure-setup.log"
    log "Adding rules to security group $sg_id"
    
    # Parse rules from JSON and add them
    echo "$sg_rules" | jq -c '.[]' | while read -r rule; do
        local protocol=$(echo "$rule" | jq -r '.protocol')
        local port=$(echo "$rule" | jq -r '.port')
        local source=$(echo "$rule" | jq -r '.source')
        
        # Handle source (could be CIDR or security group name)
        local source_param
        if [[ "$source" == *"sg"* ]]; then
            # Source is a security group
            local source_sg_id=$(grep "${source^^}_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
            if [ -z "$source_sg_id" ]; then
                echo "DEBUG: Could not find security group ID for $source" | tee -a "$SCRIPT_DIR/infrastructure-setup.log"
                echo "DEBUG: Available security groups:" | tee -a "$SCRIPT_DIR/infrastructure-setup.log"
                grep "_SG_ID=" "$RESOURCE_IDS_FILE" | tee -a "$SCRIPT_DIR/infrastructure-setup.log"
                continue
            fi
            source_param="--source-group $source_sg_id"
        else
            # Source is CIDR
            source_param="--cidr $source"
        fi
        
        log "Adding rule: $protocol $port from $source"
        echo "DEBUG: About to call AWS CLI with group-id: '$sg_id'" | tee -a "$SCRIPT_DIR/infrastructure-setup.log"
        echo "DEBUG: AWS CLI command: aws ec2 authorize-security-group-ingress --group-id '$sg_id' --protocol '$protocol' --port '$port' $source_param" | tee -a "$SCRIPT_DIR/infrastructure-setup.log"
        
        aws ec2 authorize-security-group-ingress \
            --group-id "$sg_id" \
            --protocol "$protocol" \
            --port "$port" \
            $source_param 2>&1 | tee -a "$SCRIPT_DIR/infrastructure-setup.log" || {
            echo "DEBUG: AWS CLI failed. Check log for details." | tee -a "$SCRIPT_DIR/infrastructure-setup.log"
            error_exit "Failed to add security group rule"
        }
    done
    
    success "Security group rules added"
}

# Create Backend Security Group
create_backend_security_group() {
    local sg_name=$(jq -r '.security.backend_sg.name' "$CONFIG_FILE")
    local sg_description=$(jq -r '.security.backend_sg.description' "$CONFIG_FILE")
    local sg_rules=$(jq -c '.security.backend_sg.ingress' "$CONFIG_FILE")
    
    local sg_id=$(create_security_group "$sg_name" "$sg_description" "BACKEND_SG_ID")
    add_security_group_rules "$sg_id" "$sg_rules"
}

# Create AI Service Security Group
create_ai_service_security_group() {
    local sg_name=$(jq -r '.security.ai_service_sg.name' "$CONFIG_FILE")
    local sg_description=$(jq -r '.security.ai_service_sg.description' "$CONFIG_FILE")
    local sg_rules=$(jq -c '.security.ai_service_sg.ingress' "$CONFIG_FILE")
    
    local sg_id=$(create_security_group "$sg_name" "$sg_description" "AI_SERVICE_SG_ID")
    add_security_group_rules "$sg_id" "$sg_rules"
}

# Create Database Security Group
create_database_security_group() {
    local sg_name=$(jq -r '.security.database_sg.name' "$CONFIG_FILE")
    local sg_description=$(jq -r '.security.database_sg.description' "$CONFIG_FILE")
    local sg_rules=$(jq -c '.security.database_sg.ingress' "$CONFIG_FILE")
    
    local sg_id=$(create_security_group "$sg_name" "$sg_description" "DATABASE_SG_ID")
    add_security_group_rules "$sg_id" "$sg_rules"
}

# Create IAM Role for EC2 (using LabRole)
create_iam_role() {
    log "Setting up IAM role for EC2 instances..."
    
    # For Academy Lab, we need to use the existing LabRole
    # Check if LabRole exists
    local lab_role_arn=$(aws iam get-role \
        --role-name LabRole \
        --query 'Role.Arn' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$lab_role_arn" ]; then
        warning "LabRole not found. This is required for Academy Lab compliance."
        log "Please ensure LabRole is available in your Academy Lab environment."
    else
        echo "LAB_ROLE_ARN=$lab_role_arn" >> "$RESOURCE_IDS_FILE"
        success "LabRole found: $lab_role_arn"
    fi
    
    # Check for LabInstanceProfile
    local instance_profile_arn=$(aws iam get-instance-profile \
        --instance-profile-name LabInstanceProfile \
        --query 'InstanceProfile.Arn' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$instance_profile_arn" ]; then
        warning "LabInstanceProfile not found. This is required for Academy Lab compliance."
    else
        echo "LAB_INSTANCE_PROFILE_ARN=$instance_profile_arn" >> "$RESOURCE_IDS_FILE"
        success "LabInstanceProfile found: $instance_profile_arn"
    fi
}

# Create IAM Policies for Message Queue Access
create_message_queue_policies() {
    log "Creating IAM policies for message queue access..."
    
    local project_name=$(jq -r '.project.name' "$CONFIG_FILE")
    
    # Policy for SQS access
    local sqs_policy_name="${project_name}-sqs-access"
    local sqs_policy_document='{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": [
                    "sqs:SendMessage",
                    "sqs:ReceiveMessage",
                    "sqs:DeleteMessage",
                    "sqs:GetQueueAttributes"
                ],
                "Resource": "arn:aws:sqs:us-east-1:*:*"
            }
        ]
    }'
    
    # Check if policy already exists
    local sqs_policy_arn=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='$sqs_policy_name'].Arn" --output text 2>/dev/null)
    if [ -z "$sqs_policy_arn" ] || [ "$sqs_policy_arn" = "None" ]; then
        aws iam create-policy \
            --policy-name "$sqs_policy_name" \
            --policy-document "$sqs_policy_document" \
            --description "Policy for SQS access" || echo "SQS policy creation failed"
    else
        echo "SQS policy already exists: $sqs_policy_arn"
    fi
    
    # Policy for SNS access
    local sns_policy_name="${project_name}-sns-access"
    local sns_policy_document='{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": [
                    "sns:Publish",
                    "sns:Subscribe",
                    "sns:Unsubscribe"
                ],
                "Resource": "arn:aws:sns:us-east-1:*:*"
            }
        ]
    }'
    
    # Check if policy already exists
    local sns_policy_arn=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='$sns_policy_name'].Arn" --output text 2>/dev/null)
    if [ -z "$sns_policy_arn" ] || [ "$sns_policy_arn" = "None" ]; then
        aws iam create-policy \
            --policy-name "$sns_policy_name" \
            --policy-document "$sns_policy_document" \
            --description "Policy for SNS access" || echo "SNS policy creation failed"
    else
        echo "SNS policy already exists: $sns_policy_arn"
    fi
    
    success "Message queue IAM policies created"
}

# Main execution
main() {
    log "Starting security setup..."
    
    # Check if resource IDs file exists
    if [ ! -f "$RESOURCE_IDS_FILE" ]; then
        error_exit "Resource IDs file not found. Please run setup-vpc.sh first."
    fi
    
    create_backend_security_group
    create_ai_service_security_group
    create_database_security_group
    create_iam_role
    create_message_queue_policies
    
    success "Security setup completed successfully!"
    
    # Display created resources
    echo "=========================================="
    echo "Security Resources Created:"
    echo "=========================================="
    grep -E "(SG_ID|LAB_ROLE|LAB_INSTANCE_PROFILE)" "$RESOURCE_IDS_FILE"
    echo "=========================================="
}

# Execute main function
main "$@"
