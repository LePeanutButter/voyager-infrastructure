#!/bin/bash
# Infrastructure Destroy Script for SmartTrip
# Safely removes all AWS resources created by the setup scripts

set -e
export AWS_PAGER=""

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

aws_sqs() {
    if [ -n "${AWS_ENDPOINT_URL:-}" ]; then
        aws --endpoint-url "$AWS_ENDPOINT_URL" sqs "$@"
    else
        aws sqs "$@"
    fi
}

aws_rds() {
    if [ -n "${AWS_ENDPOINT_URL:-}" ]; then
        aws --endpoint-url "$AWS_ENDPOINT_URL" rds "$@"
    else
        aws rds "$@"
    fi
}

# Delete EC2 key pair and local PEM file
delete_key_pair() {
    local key_name="$1"
    local pem_file="$SCRIPT_DIR/${key_name}.pem"
    
    log "Deleting EC2 key pair: $key_name"
    
    # Delete from AWS
    aws ec2 delete-key-pair \
        --key-name "$key_name" \
        2>/dev/null || warning "Failed to delete key pair: $key_name"
    
    # Remove local PEM file
    if [ -f "$pem_file" ]; then
        rm -f "$pem_file"
        log "Local PEM file removed: $pem_file"
    fi
    
    success "Key pair deleted: $key_name"
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
    if [ "${DESTROY_ASSUME_YES:-}" = "1" ]; then
        confirm="yes"
        echo "DESTROY_ASSUME_YES=1 — continuando sin prompt interactivo."
    else
        read -r -p "Are you sure you want to continue? (yes/no): " confirm || confirm="no"
    fi
    
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
        warning "resource-ids.txt no encontrado: el borrado en AWS por IDs será limitado; al final se limpiará el workspace local igualmente."
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
            aws_sqs delete-queue --queue-url "$queue_url" || warning "Failed to delete SQS queue: $queue_url"
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
            
            # Wait for instances to terminate (removed wait command since we force delete)
            
            # Delete ASG
            aws autoscaling delete-auto-scaling-group \
                --auto-scaling-group-name "$asg_name" \
                --force-delete || warning "Failed to delete ASG: $asg_name"
            success "Auto Scaling Group deleted: $asg_name"
        fi
    done

    local project_name
    project_name=$(jq -r '.project.name' "$CONFIG_FILE")

    # ASG por nombre (restos si resource-ids incompleto o ejecución previa fallida)
    for orphan_asg in "${project_name}-backend-asg" "${project_name}-ai-service-asg"; do
        local exists
        exists=$(aws autoscaling describe-auto-scaling-groups \
            --auto-scaling-group-names "$orphan_asg" \
            --query 'AutoScalingGroups[0].AutoScalingGroupName' \
            --output text 2>/dev/null || echo "")
        if [ -n "$exists" ] && [ "$exists" != "None" ]; then
            log "Deleting orphaned Auto Scaling Group: $orphan_asg"
            aws autoscaling update-auto-scaling-group \
                --auto-scaling-group-name "$orphan_asg" \
                --desired-capacity 0 \
                --min-size 0 \
                --max-size 0 2>/dev/null || true
            aws autoscaling delete-auto-scaling-group \
                --auto-scaling-group-name "$orphan_asg" \
                --force-delete 2>/dev/null || warning "Failed to delete orphaned ASG: $orphan_asg"
        fi
    done

    # Cualquier ALB del proyecto (LocalStack puede dejar varios ARNs; hay que quitar listeners antes del TG)
    log "Deleting ELBv2 load balancers matching project '$project_name'..."
    local all_lb_arns
    all_lb_arns=$(aws elbv2 describe-load-balancers \
        --query "LoadBalancers[?contains(LoadBalancerName, \`${project_name}\`)].LoadBalancerArn" \
        --output text 2>/dev/null || echo "")
    for lb_arn in $all_lb_arns; do
        [ -z "$lb_arn" ] || [ "$lb_arn" = "None" ] && continue
        log "Deleting listeners and load balancer: $lb_arn"
        local lis
        lis=$(aws elbv2 describe-listeners \
            --load-balancer-arn "$lb_arn" \
            --query 'Listeners[].ListenerArn' \
            --output text 2>/dev/null || echo "")
        for la in $lis; do
            aws elbv2 delete-listener --listener-arn "$la" 2>/dev/null || true
        done
        aws elbv2 delete-load-balancer --load-balancer-arn "$lb_arn" 2>/dev/null || warning "Failed to delete load balancer $lb_arn"
    done
    sleep 3

    delete_target_group_by_arn_or_name() {
        local tg_arn="$1"
        local tg_name="$2"
        local arn="$tg_arn"
        if [ -z "$arn" ] || [ "$arn" = "None" ]; then
            arn=$(aws elbv2 describe-target-groups \
                --names "$tg_name" \
                --query 'TargetGroups[0].TargetGroupArn' \
                --output text 2>/dev/null || echo "")
        fi
        if [ -n "$arn" ] && [ "$arn" != "None" ]; then
            log "Deleting Target Group: $arn"
            aws elbv2 delete-target-group --target-group-arn "$arn" || warning "Failed to delete target group: $arn"
        fi
    }

    local tg_arn_file
    tg_arn_file=$(grep "BACKEND_TG_ARN=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
    delete_target_group_by_arn_or_name "$tg_arn_file" "${project_name}-backend-tg"
    tg_arn_file=$(grep "AI_SERVICE_TG_ARN=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
    delete_target_group_by_arn_or_name "$tg_arn_file" "${project_name}-ai-service-tg"
    
    # Delete Launch Templates
    local launch_templates=("BACKEND_LT_ID" "AI_SERVICE_LT_ID")
    for lt_key in "${launch_templates[@]}"; do
        local lt_id=$(grep "$lt_key=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
        if [ -n "$lt_id" ]; then
            log "Deleting Launch Template: $lt_id"
            aws ec2 delete-launch-template --launch-template-id "$lt_id" || warning "Failed to delete launch template: $lt_id"
        fi
    done

    aws ec2 delete-launch-template --launch-template-name "${project_name}-backend-lt" >/dev/null 2>&1 || true
    aws ec2 delete-launch-template --launch-template-name "${project_name}-ai-service-lt" >/dev/null 2>&1 || true
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
            aws_rds delete-db-instance \
                --db-instance-identifier "$db_id" \
                --skip-final-snapshot \
                --delete-automated-backups || warning "Failed to delete RDS instance: $db_id"
            
            # Wait for instance to be deleted
            aws_rds wait db-instance-deleted --db-instance-identifier "$db_id" || warning "RDS deletion wait timeout"
            success "RDS instance deleted: $db_id"
        fi
    done
    
    # Delete DB subnet group
    local db_subnet_group_name=$(grep "DB_SUBNET_GROUP_NAME=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
    if [ -n "$db_subnet_group_name" ]; then
        log "Deleting DB subnet group: $db_subnet_group_name"
        aws_rds delete-db-subnet-group --db-subnet-group-name "$db_subnet_group_name" || warning "Failed to delete DB subnet group"
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
    
    # Políticas IAM creadas por setup-security (no son LabRole)
    local pol
    for pol in smarttrip-sqs-access smarttrip-sns-access; do
        local pol_arn
        pol_arn=$(aws iam list-policies \
            --scope Local \
            --query "Policies[?PolicyName=='$pol'].Arn" \
            --output text 2>/dev/null || echo "")
        if [ -n "$pol_arn" ] && [ "$pol_arn" != "None" ]; then
            log "Deleting IAM policy: $pol_arn"
            aws iam delete-policy --policy-arn "$pol_arn" >/dev/null 2>&1 || warning "Failed to delete IAM policy: $pol"
        fi
    done

    # Note: LabRole and LabInstanceProfile are not deleted as they are Academy Lab resources
}

# Destroy VPC Resources
destroy_vpc() {
    log "Destroying VPC resources..."

    local rtb_id vpc_id igw_id
    rtb_id=$(grep "RTB_ID=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
    vpc_id=$(grep "VPC_ID=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
    igw_id=$(grep "IGW_ID=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)

    # 1. Disassociate route table FIRST
    local subnet_count
    subnet_count=$(jq '.vpc.public_subnets | length' "$CONFIG_FILE")
    for ((i=0; i<subnet_count; i++)); do
        local association_id
        association_id=$(grep "RT_ASSOC_${i}_ID=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
        if [ -n "$association_id" ]; then
            log "Disassociating Route Table Association: $association_id"
            aws ec2 disassociate-route-table --association-id "$association_id" || warning "Failed to disassociate: $association_id"
        fi
    done

    # 2. Now delete the route table
    if [ -n "$rtb_id" ]; then
        log "Deleting Route Table: $rtb_id"
        aws ec2 delete-route-table --route-table-id "$rtb_id" || error_exit "Failed to delete route table: $rtb_id"
        success "Route Table deleted"
    fi

    # 3. Delete subnets
    for ((i=0; i<subnet_count; i++)); do
        local subnet_id
        subnet_id=$(grep "SUBNET_${i}_ID=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
        if [ -n "$subnet_id" ]; then
            log "Deleting Subnet: $subnet_id"
            aws ec2 delete-subnet --subnet-id "$subnet_id" || warning "Failed to delete subnet: $subnet_id"
            success "Subnet deleted: $subnet_id"
        fi
    done

    # 4. Detach and delete IGW
    if [ -n "$igw_id" ] && [ -n "$vpc_id" ]; then
        log "Detaching Internet Gateway: $igw_id"
        aws ec2 detach-internet-gateway --internet-gateway-id "$igw_id" --vpc-id "$vpc_id" || warning "Failed to detach IGW"
        log "Deleting Internet Gateway: $igw_id"
        aws ec2 delete-internet-gateway --internet-gateway-id "$igw_id" || warning "Failed to delete IGW"
        success "Internet Gateway deleted"
    fi

    # 5. Before deleting VPC, clean up all remaining dependencies
    if [ -n "$vpc_id" ]; then
        log "Cleaning up remaining VPC dependencies..."
        
        # Delete any remaining network interfaces
        log "Deleting network interfaces..."
        local enis
        enis=$(aws ec2 describe-network-interfaces \
            --filters "Name=vpc-id,Values=$vpc_id" \
            --query 'NetworkInterfaces[?Status!=`in-use`].NetworkInterfaceId' \
            --output text 2>/dev/null || echo "")
        for eni in $enis; do
            log "Deleting network interface: $eni"
            aws ec2 delete-network-interface --network-interface-id "$eni" 2>/dev/null || log "Failed to delete ENI: $eni"
        done
        
        # Delete any remaining NAT gateways
        log "Deleting NAT gateways..."
        local nat_gws
        nat_gws=$(aws ec2 describe-nat-gateways \
            --filter "Name=vpc-id,Values=$vpc_id" \
            --query 'NatGateways[].NatGatewayId' \
            --output text 2>/dev/null || echo "")
        for nat in $nat_gws; do
            log "Deleting NAT gateway: $nat"
            aws ec2 delete-nat-gateway --nat-gateway-id "$nat" 2>/dev/null || log "Failed to delete NAT: $nat"
        done
        
        # Delete any remaining Elastic IPs
        log "Deleting Elastic IPs..."
        local eips
        eips=$(aws ec2 describe-addresses \
            --filters "Name=vpc-id,Values=$vpc_id" \
            --query 'Addresses[].AllocationId' \
            --output text 2>/dev/null || echo "")
        for eip in $eips; do
            log "Releasing Elastic IP: $eip"
            aws ec2 release-address --allocation-id "$eip" 2>/dev/null || log "Failed to release EIP: $eip"
        done
        
        # Force delete remaining subnets with dependencies
        log "Force deleting remaining subnets..."
        local remaining_subnets
        remaining_subnets=$(aws ec2 describe-subnets \
            --filters "Name=vpc-id,Values=$vpc_id" \
            --query 'Subnets[].SubnetId' \
            --output text 2>/dev/null || echo "")
        for subnet in $remaining_subnets; do
            log "Force deleting subnet: $subnet"
            aws ec2 delete-subnet --subnet-id "$subnet" 2>/dev/null || warning "Failed to delete subnet: $subnet"
        done
        
        # Clean up remaining security groups
        log "Cleaning up remaining security groups in VPC..."
        local remaining_sgs
        remaining_sgs=$(aws ec2 describe-security-groups \
            --filters "Name=vpc-id,Values=$vpc_id" \
            --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
            --output text 2>/dev/null || echo "")
        for sg in $remaining_sgs; do
            log "Deleting leftover security group: $sg"
            aws ec2 delete-security-group --group-id "$sg" || warning "Failed to delete sg: $sg"
        done
    fi

    # 6. Delete VPC last
    if [ -n "$vpc_id" ]; then
        log "Deleting VPC: $vpc_id"
        aws ec2 delete-vpc --vpc-id "$vpc_id" || error_exit "Failed to delete VPC: $vpc_id"
        success "VPC deleted: $vpc_id"
    fi
}

# Clean up EC2 key pairs
cleanup_key_pairs() {
    log "Cleaning up EC2 key pairs..."
    
    local key_names
    key_names=($(jq -r '.compute | to_entries[].value.key_name' "$CONFIG_FILE" 2>/dev/null | sort -u | grep -v null))
    
    for key_name in "${key_names[@]}"; do
        delete_key_pair "$key_name"
    done
}

# Borra artefactos locales siempre (ejecuciones nuevas limpias).
# Nota: los globs no deben ir entre comillas para expandir en bash.
cleanup_local_workspace() {
    log "Limpiando artefactos locales (logs, resource-ids, tmp, PEM)..."

    rm -f "$RESOURCE_IDS_FILE"

    rm -f "$SCRIPT_DIR/infrastructure-setup.log"
    rm -f "$SCRIPT_DIR/infrastructure-destroy.log"
    rm -f "$SCRIPT_DIR"/infrastructure-setup-*.log
    rm -f "$SCRIPT_DIR"/infrastructure-destroy-*.log
    rm -f "$SCRIPT_DIR"/*.log

    rm -f "$SCRIPT_DIR/backend_db_status.tmp" "$SCRIPT_DIR/ai_service_db_status.tmp"
    rm -f "$SCRIPT_DIR"/*_db_status.tmp

    local key_name
    while IFS= read -r key_name; do
        [ -z "$key_name" ] || [ "$key_name" = "null" ] && continue
        rm -f "$SCRIPT_DIR/${key_name}.pem"
        rm -f "$SCRIPT_DIR"/"${key_name}"-*.pem
    done < <(jq -r '.compute | to_entries[].value.key_name' "$CONFIG_FILE" 2>/dev/null | sort -u)

    success "Workspace local limpio"
}

# Elimina claves en AWS y PEM locales (antes de borrar logs masivos).
finalize_local_after_aws() {
    log "Eliminando key pairs en AWS y archivos PEM locales..."
    cleanup_key_pairs
    cleanup_local_workspace
}

# Main destruction execution
main() {
    echo "=========================================="
    echo "SmartTrip Infrastructure Destruction"
    echo "=========================================="
    
    confirm_destruction

    # Si algo falla en AWS, igual dejamos el directorio sin logs/pem/resource-ids.
    trap finalize_local_after_aws EXIT

    check_dependencies
    
    log "Starting infrastructure destruction..."
    
    # Destroy in correct order to handle dependencies
    destroy_monitoring      # CloudWatch resources
    destroy_compute        # Auto Scaling Groups, Load Balancers, Launch Templates
    destroy_networking     # SQS, SNS, API Gateway
    destroy_storage        # S3 buckets
    destroy_databases      # RDS instances
    destroy_security       # Security groups + IAM policies SmartTrip
    destroy_vpc            # VPC resources (subnets, route tables, IGW, VPC)
    
    trap - EXIT
    finalize_local_after_aws
    
    echo "=========================================="
    echo "Infrastructure destruction completed!"
    echo "=========================================="
    success "All SmartTrip resources have been destroyed"
    rm -f "$SCRIPT_DIR/infrastructure-destroy.log"
}

# Execute main function
main "$@"
