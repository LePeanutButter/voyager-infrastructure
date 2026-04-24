#!/bin/bash
# Infrastructure Destroy Script for SmartTrip
# Safely removes all AWS resources created by the setup scripts

set -e

# Source configuration and utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"

# Resource ID storage
RESOURCE_IDS_FILE="$SCRIPT_DIR/resource-ids.txt"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Destroy - $1" | tee -a "$SCRIPT_DIR/infrastructure-destroy.log"
}

# Error handling
error_exit() {
    echo "ERROR: $1" | tee -a "$SCRIPT_DIR/infrastructure-destroy.log"
    exit 1
}

# Success message
success() {
    echo "SUCCESS: $1" | tee -a "$SCRIPT_DIR/infrastructure-destroy.log"
}

# Warning message
warning() {
    echo "WARNING: $1" | tee -a "$SCRIPT_DIR/infrastructure-destroy.log"
}

# Confirmation prompt
confirm_destruction() {
    echo "=========================================="
    echo "WARNING: This will destroy ALL SmartTrip infrastructure"
    echo "Project: $(jq -r '.project.name' "$CONFIG_FILE")"
    echo "Environment: $(jq -r '.project.environment' "$CONFIG_FILE")"
    echo "=========================================="
    echo "This action cannot be undone!"
    echo ""
    read -p "Are you sure you want to continue? (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        echo "Destruction cancelled by user"
        exit 0
    fi
}

# Check dependencies
check_dependencies() {
    log "Checking dependencies..."
    
    if ! command -v aws &> /dev/null; then
        error_exit "AWS CLI is not installed"
    fi
    
    if ! aws sts get-caller-identity &> /dev/null; then
        error_exit "AWS credentials not configured"
    fi
    
    if [ ! -f "$RESOURCE_IDS_FILE" ]; then
        error_exit "Resource IDs file not found. Cannot safely destroy infrastructure."
    fi
    
    success "Dependencies check passed"
}

# Destroy Monitoring Resources
destroy_monitoring() {
    log "Destroying monitoring resources..."
    
    # Delete CloudWatch alarms
    local project_name=$(jq -r '.project.name' "$CONFIG_FILE")
    local alarms=$(aws cloudwatch describe-alarms \
        --alarm-name-prefix "$project_name" \
        --query 'MetricAlarms[].AlarmName' \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$alarms" ]; then
        echo "$alarms" | while read -r alarm; do
            if [ -n "$alarm" ]; then
                log "Deleting alarm: $alarm"
                aws cloudwatch delete-alarms --alarm-names "$alarm" || warning "Failed to delete alarm: $alarm"
            fi
        done
        success "CloudWatch alarms deleted"
    fi
    
    # Delete CloudWatch dashboard
    local dashboard_name=$(grep "DASHBOARD_NAME=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
    if [ -n "$dashboard_name" ]; then
        log "Deleting dashboard: $dashboard_name"
        aws cloudwatch delete-dashboards --dashboard-names "$dashboard_name" || warning "Failed to delete dashboard: $dashboard_name"
        success "CloudWatch dashboard deleted"
    fi
    
    # Delete CloudWatch log groups
    local log_groups=($(jq -r '.monitoring.log_groups[]' "$CONFIG_FILE"))
    for log_group in "${log_groups[@]}"; do
        log "Deleting log group: $log_group"
        # Check if log group exists before attempting deletion
        if aws logs describe-log-groups --log-group-name-prefix "$log_group" --query 'logGroups[?logGroupName==`'$log_group'`].logGroupName' --output text 2>/dev/null | grep -q "$log_group"; then
            aws logs delete-log-group --log-group-name "$log_group" || warning "Failed to delete log group: $log_group"
        else
            log "Log group $log_group does not exist, skipping"
        fi
    done
    success "CloudWatch log groups deleted"
}

# Destroy Networking Resources
destroy_networking() {
    log "Destroying networking resources..."
    
    # Delete SNS subscriptions
    local system_events_topic_arn=$(grep "SYSTEM_EVENTS_TOPIC_ARN=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
    if [ -n "$system_events_topic_arn" ]; then
        local subscriptions=$(aws sns list-subscriptions-by-topic \
            --topic-arn "$system_events_topic_arn" \
            --query 'Subscriptions[].SubscriptionArn' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$subscriptions" ]; then
            echo "$subscriptions" | while read -r subscription; do
                if [ -n "$subscription" ]; then
                    log "Deleting subscription: $subscription"
                    aws sns unsubscribe --subscription-arn "$subscription" || warning "Failed to delete subscription: $subscription"
                fi
            done
        fi
    fi
    
    # Delete SNS topics
    local topics=("USER_EVENTS_TOPIC_ARN" "RECOMMENDATION_EVENTS_TOPIC_ARN" "SYSTEM_EVENTS_TOPIC_ARN")
    for topic_key in "${topics[@]}"; do
        local topic_arn=$(grep "$topic_key=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
        if [ -n "$topic_arn" ]; then
            log "Deleting SNS topic: $topic_arn"
            aws sns delete-topic --topic-arn "$topic_arn" || warning "Failed to delete SNS topic: $topic_arn"
        fi
    done
    success "SNS topics deleted"
    
    # Delete SQS queues
    local queues=("USER_EVENTS_QUEUE_URL" "RECOMMENDATION_EVENTS_QUEUE_URL" "ANALYTICS_EVENTS_QUEUE_URL")
    for queue_key in "${queues[@]}"; do
        local queue_url=$(grep "$queue_key=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
        if [ -n "$queue_url" ]; then
            log "Deleting SQS queue: $queue_url"
            aws sqs delete-queue --queue-url "$queue_url" || warning "Failed to delete SQS queue: $queue_url"
        fi
    done
    success "SQS queues deleted"
    
    # Delete API Gateway
    local api_id=$(grep "API_GATEWAY_ID=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
    if [ -n "$api_id" ]; then
        log "Deleting API Gateway: $api_id"
        
        # Delete deployment
        local deployment_id=$(grep "API_DEPLOYMENT_ID=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
        if [ -n "$deployment_id" ]; then
            aws apigateway delete-deployment --rest-api-id "$api_id" --deployment-id "$deployment_id" || warning "Failed to delete API deployment"
        fi
        
        # Delete REST API
        aws apigateway delete-rest-api --rest-api-id "$api_id" || warning "Failed to delete API Gateway"
        success "API Gateway deleted"
    fi
}

# Destroy Storage Resources
destroy_storage() {
    log "Destroying storage resources..."
    
    # Empty and delete S3 buckets
    local buckets=("FRONTEND_BUCKET" "MEDIA_BUCKET" "LOGS_BUCKET")
    for bucket_key in "${buckets[@]}"; do
        local bucket_name=$(grep "$bucket_key=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
        if [ -n "$bucket_name" ]; then
            log "Emptying S3 bucket: $bucket_name"
            
            # Delete all objects and versions
            aws s3 rm "s3://$bucket_name" --recursive || warning "Failed to empty bucket: $bucket_name"
            
            # Delete all versions and delete markers (for versioned buckets)
            aws s3api delete-objects --bucket "$bucket_name" --delete "$(aws s3api list-object-versions --bucket "$bucket_name" --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null || echo '{"Objects":[]}')" 2>/dev/null || true
            aws s3api delete-objects --bucket "$bucket_name" --delete "$(aws s3api list-object-versions --bucket "$bucket_name" --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null || echo '{"Objects":[]}')" 2>/dev/null || true
            
            # Delete bucket
            aws s3 rb "s3://$bucket_name" || warning "Failed to delete bucket: $bucket_name"
            success "S3 bucket deleted: $bucket_name"
        fi
    done
}

# Destroy Compute Resources
destroy_compute() {
    log "Destroying compute resources..."
    
    # Delete Auto Scaling Groups
    local asg_names=("BACKEND_ASG_NAME" "AI_SERVICE_ASG_NAME")
    for asg_key in "${asg_names[@]}"; do
        local asg_name=$(grep "$asg_key=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
        if [ -n "$asg_name" ]; then
            log "Deleting Auto Scaling Group: $asg_name"
            
            # Update desired capacity to 0
            aws autoscaling update-auto-scaling-group \
                --auto-scaling-group-name "$asg_name" \
                --desired-capacity 0 \
                --min-size 0 \
                --max-size 0 || warning "Failed to update ASG capacity"
            
            # Wait for instances to terminate
            aws autoscaling wait auto-scaling-group-in-service \
                --auto-scaling-group-names "$asg_name" || warning "ASG wait timeout"
            
            # Delete ASG
            aws autoscaling delete-auto-scaling-group \
                --auto-scaling-group-name "$asg_name" \
                --force-delete || warning "Failed to delete ASG: $asg_name"
            success "Auto Scaling Group deleted: $asg_name"
        fi
    done
    
    # Delete Target Groups
    local target_groups=("BACKEND_TG_ARN" "AI_SERVICE_TG_ARN")
    for tg_key in "${target_groups[@]}"; do
        local tg_arn=$(grep "$tg_key=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
        if [ -n "$tg_arn" ]; then
            log "Deleting Target Group: $tg_arn"
            aws elbv2 delete-target-group --target-group-arn "$tg_arn" || warning "Failed to delete target group: $tg_arn"
        fi
    done
    
    # Delete Load Balancer
    local lb_name=$(grep "LB_NAME=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
    if [ -n "$lb_name" ]; then
        log "Deleting Load Balancer: $lb_name"
        # Get load balancer ARN from name
        local lb_arn=$(aws elbv2 describe-load-balancers --names "$lb_name" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "")
        if [ -n "$lb_arn" ]; then
            aws elbv2 delete-load-balancer --load-balancer-arn "$lb_arn" || warning "Failed to delete load balancer: $lb_name"
        else
            aws elbv2 delete-load-balancer --name "$lb_name" || warning "Failed to delete load balancer: $lb_name"
        fi
        success "Load Balancer deleted: $lb_name"
    fi
    
    # Delete Launch Templates
    local launch_templates=("BACKEND_LT_ID" "AI_SERVICE_LT_ID")
    for lt_key in "${launch_templates[@]}"; do
        local lt_id=$(grep "$lt_key=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
        if [ -n "$lt_id" ]; then
            log "Deleting Launch Template: $lt_id"
            aws ec2 delete-launch-template --launch-template-id "$lt_id" || warning "Failed to delete launch template: $lt_id"
        fi
    done
}

# Destroy Database Resources
destroy_databases() {
    log "Destroying database resources..."
    
    # Delete RDS instances
    local db_identifiers=("BACKEND_DB_ID" "AI_SERVICE_DB_ID")
    for db_key in "${db_identifiers[@]}"; do
        local db_id=$(grep "$db_key=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
        if [ -n "$db_id" ]; then
            log "Deleting RDS instance: $db_id"
            aws rds delete-db-instance \
                --db-instance-identifier "$db_id" \
                --skip-final-snapshot \
                --delete-automated-backups || warning "Failed to delete RDS instance: $db_id"
            
            # Wait for instance to be deleted
            aws rds wait db-instance-deleted --db-instance-identifier "$db_id" || warning "RDS deletion wait timeout"
            success "RDS instance deleted: $db_id"
        fi
    done
    
    # Delete DB subnet group
    local db_subnet_group_name=$(grep "DB_SUBNET_GROUP_NAME=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
    if [ -n "$db_subnet_group_name" ]; then
        log "Deleting DB subnet group: $db_subnet_group_name"
        aws rds delete-db-subnet-group --db-subnet-group-name "$db_subnet_group_name" || warning "Failed to delete DB subnet group"
        success "DB subnet group deleted"
    fi
}

# Destroy Security Resources
destroy_security() {
    log "Destroying security resources..."
    
    # Delete security groups
    local security_groups=("BACKEND_SG_ID" "AI_SERVICE_SG_ID" "DATABASE_SG_ID")
    for sg_key in "${security_groups[@]}"; do
        local sg_id=$(grep "$sg_key=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
        if [ -n "$sg_id" ]; then
            log "Deleting Security Group: $sg_id"
            aws ec2 delete-security-group --group-id "$sg_id" || warning "Failed to delete security group: $sg_id"
            success "Security Group deleted: $sg_id"
        fi
    done
    
    # Note: LabRole and LabInstanceProfile are not deleted as they are Academy Lab resources
}

# Destroy VPC Resources
destroy_vpc() {
    log "Destroying VPC resources..."
    
    # Delete route tables
    local rtb_id=$(grep "RTB_ID=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
    if [ -n "$rtb_id" ]; then
        log "Deleting Route Table: $rtb_id"
        aws ec2 delete-route-table --route-table-id "$rtb_id" || warning "Failed to delete route table: $rtb_id"
        success "Route Table deleted"
    fi
    
    # Delete route table associations
    local subnet_count=$(jq '.vpc.public_subnets | length' "$CONFIG_FILE")
    for ((i=0; i<subnet_count; i++)); do
        local association_id=$(grep "RT_ASSOC_${i}_ID=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
        if [ -n "$association_id" ]; then
            log "Deleting Route Table Association: $association_id"
            aws ec2 disassociate-route-table --association-id "$association_id" || warning "Failed to delete route table association: $association_id"
        fi
    done
    
    # Delete subnets
    for ((i=0; i<subnet_count; i++)); do
        local subnet_id=$(grep "SUBNET_${i}_ID=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
        if [ -n "$subnet_id" ]; then
            log "Deleting Subnet: $subnet_id"
            aws ec2 delete-subnet --subnet-id "$subnet_id" || warning "Failed to delete subnet: $subnet_id"
            success "Subnet deleted: $subnet_id"
        fi
    done
    
    # Delete Internet Gateway
    local igw_id=$(grep "IGW_ID=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
    local vpc_id=$(grep "VPC_ID=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
    
    if [ -n "$igw_id" ] && [ -n "$vpc_id" ]; then
        log "Detaching Internet Gateway: $igw_id"
        aws ec2 detach-internet-gateway --internet-gateway-id "$igw_id" --vpc-id "$vpc_id" || warning "Failed to detach Internet Gateway"
        
        log "Deleting Internet Gateway: $igw_id"
        aws ec2 delete-internet-gateway --internet-gateway-id "$igw_id" || warning "Failed to delete Internet Gateway"
        success "Internet Gateway deleted"
    fi
    
    # Delete VPC
    if [ -n "$vpc_id" ]; then
        log "Deleting VPC: $vpc_id"
        aws ec2 delete-vpc --vpc-id "$vpc_id" || warning "Failed to delete VPC: $vpc_id"
        success "VPC deleted: $vpc_id"
    fi
}

# Cleanup
cleanup() {
    log "Cleaning up..."
    
    # Remove resource IDs file
    if [ -f "$RESOURCE_IDS_FILE" ]; then
        rm "$RESOURCE_IDS_FILE"
        success "Resource IDs file removed"
    fi
    
    # Remove log files (optional)
    read -p "Remove log files? (yes/no): " remove_logs
    if [ "$remove_logs" = "yes" ]; then
        rm -f "$SCRIPT_DIR/infrastructure-setup.log"
        rm -f "$SCRIPT_DIR/infrastructure-destroy.log"
        success "Log files removed"
    fi
}

# Main destruction execution
main() {
    echo "=========================================="
    echo "SmartTrip Infrastructure Destruction"
    echo "=========================================="
    
    confirm_destruction
    check_dependencies
    
    log "Starting infrastructure destruction..."
    
    # Destroy in correct order to handle dependencies
    destroy_monitoring      # CloudWatch resources
    destroy_compute        # Auto Scaling Groups, Load Balancers, Launch Templates
    destroy_networking     # SQS, SNS, API Gateway
    destroy_storage        # S3 buckets
    destroy_databases      # RDS instances
    destroy_security       # Security groups (last before VPC)
    destroy_vpc            # VPC resources (subnets, route tables, IGW, VPC)
    
    cleanup
    
    echo "=========================================="
    echo "Infrastructure destruction completed!"
    echo "=========================================="
    success "All SmartTrip resources have been destroyed"
}

# Execute main function
main "$@"
