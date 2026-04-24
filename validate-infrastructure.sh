#!/bin/bash
# Infrastructure Validation Script for SmartTrip
# Validates all created resources and provides status report

set -e

# Source configuration and utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"

# Resource ID storage
RESOURCE_IDS_FILE="$SCRIPT_DIR/resource-ids.txt"

# Logging function
log() {
    echo "$(date "+%Y-%m-%d %H:%M:%S") - Validation - $1" | tee -a "$SCRIPT_DIR/infrastructure-setup.log"
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

# Warning message
warning() {
    echo "WARNING: $1" | tee -a "$SCRIPT_DIR/infrastructure-setup.log"
}

# Validation counters
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0

# Increment counters
increment_counters() {
    local result="$1"
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    
    if [ "$result" = "PASS" ]; then
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
}

# Validate VPC Resources
validate_vpc() {
    log "Validating VPC resources..."
    
    local vpc_id=$(grep "VPC_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    
    if [ -n "$vpc_id" ]; then
        local vpc_state=$(aws ec2 describe-vpcs \
            --vpc-ids "$vpc_id" \
            --query 'Vpcs[0].State' \
            --output text 2>/dev/null)
        
        if [ "$vpc_state" = "available" ]; then
            success "VPC is available: $vpc_id"
            increment_counters "PASS"
        else
            error_exit "VPC state is not available: $vpc_state"
            increment_counters "FAIL"
        fi
    else
        error_exit "VPC ID not found"
        increment_counters "FAIL"
    fi
    
    # Validate Internet Gateway
    local igw_id=$(grep "IGW_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    if [ -n "$igw_id" ]; then
        local igw_state=$(aws ec2 describe-internet-gateways \
            --internet-gateway-ids "$igw_id" \
            --query 'InternetGateways[0].Attachments[0].State' \
            --output text 2>/dev/null)
        
        if [ "$igw_state" = "available" ]; then
            success "Internet Gateway is attached: $igw_id"
            increment_counters "PASS"
        else
            error_exit "Internet Gateway not attached: $igw_state"
            increment_counters "FAIL"
        fi
    fi
}

# Validate Security Groups
validate_security_groups() {
    log "Validating security groups..."
    
    # Backend Security Group
    local backend_sg_id=$(grep "BACKEND_SG_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    if [ -n "$backend_sg_id" ]; then
        local sg_name=$(aws ec2 describe-security-groups \
            --group-ids "$backend_sg_id" \
            --query 'SecurityGroups[0].GroupName' \
            --output text 2>/dev/null)
        
        if [ -n "$sg_name" ]; then
            success "Backend security group exists: $sg_name"
            increment_counters "PASS"
        else
            error_exit "Backend security group not found"
            increment_counters "FAIL"
        fi
    fi
    
    # AI Service Security Group
    local ai_service_sg_id=$(grep "AI_SERVICE_SG_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    if [ -n "$ai_service_sg_id" ]; then
        local sg_name=$(aws ec2 describe-security-groups \
            --group-ids "$ai_service_sg_id" \
            --query 'SecurityGroups[0].GroupName' \
            --output text 2>/dev/null)
        
        if [ -n "$sg_name" ]; then
            success "AI service security group exists: $sg_name"
            increment_counters "PASS"
        else
            error_exit "AI service security group not found"
            increment_counters "FAIL"
        fi
    fi
    
    # Database Security Group
    local database_sg_id=$(grep "DATABASE_SG_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    if [ -n "$database_sg_id" ]; then
        local sg_name=$(aws ec2 describe-security-groups \
            --group-ids "$database_sg_id" \
            --query 'SecurityGroups[0].GroupName' \
            --output text 2>/dev/null)
        
        if [ -n "$sg_name" ]; then
            success "Database security group exists: $sg_name"
            increment_counters "PASS"
        else
            error_exit "Database security group not found"
            increment_counters "FAIL"
        fi
    fi
}

# Validate Databases
validate_databases() {
    log "Validating databases..."
    
    # Backend Database
    local backend_db_id=$(grep "BACKEND_DB_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    if [ -n "$backend_db_id" ]; then
        local db_status=$(aws rds describe-db-instances \
            --db-instance-identifier "$backend_db_id" \
            --query 'DBInstances[0].DBInstanceStatus' \
            --output text 2>/dev/null)
        
        if [ "$db_status" = "available" ]; then
            local db_endpoint=$(grep "BACKEND_DB_ENDPOINT=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
            success "Backend database is available: $backend_db_id ($db_endpoint)"
            increment_counters "PASS"
        else
            warning "Backend database status: $db_status"
            increment_counters "FAIL"
        fi
    fi
    
    # AI Service Database
    local ai_service_db_id=$(grep "AI_SERVICE_DB_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    if [ -n "$ai_service_db_id" ]; then
        local db_status=$(aws rds describe-db-instances \
            --db-instance-identifier "$ai_service_db_id" \
            --query 'DBInstances[0].DBInstanceStatus' \
            --output text 2>/dev/null)
        
        if [ "$db_status" = "available" ]; then
            local db_endpoint=$(grep "AI_SERVICE_DB_ENDPOINT=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
            success "AI service database is available: $ai_service_db_id ($db_endpoint)"
            increment_counters "PASS"
        else
            warning "AI service database status: $db_status"
            increment_counters "FAIL"
        fi
    fi
}

# Validate Compute Resources
validate_compute() {
    log "Validating compute resources..."
    
    # Load Balancer
    local lb_name=$(grep "LB_NAME=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    if [ -n "$lb_name" ]; then
        local lb_state=$(aws elbv2 describe-load-balancers \
            --names "$lb_name" \
            --query 'LoadBalancers[0].State.Code' \
            --output text 2>/dev/null)
        
        if [ "$lb_state" = "active" ]; then
            local lb_dns=$(aws elbv2 describe-load-balancers \
                --names "$lb_name" \
                --query 'LoadBalancers[0].DNSName' \
                --output text 2>/dev/null)
            success "Load Balancer is active: $lb_name ($lb_dns)"
            increment_counters "PASS"
        else
            error_exit "Load Balancer state: $lb_state"
            increment_counters "FAIL"
        fi
    fi
    
    # Backend Auto Scaling Group
    local backend_asg_name=$(grep "BACKEND_ASG_NAME=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    if [ -n "$backend_asg_name" ]; then
        local asg_instances=$(aws autoscaling describe-auto-scaling-groups \
            --auto-scaling-group-names "$backend_asg_name" \
            --query 'AutoScalingGroups[0].Instances | length' \
            --output text 2>/dev/null)
        
        if [ "$asg_instances" -gt 0 ]; then
            success "Backend ASG has $asg_instances instances"
            increment_counters "PASS"
        else
            warning "Backend ASG has no instances"
            increment_counters "FAIL"
        fi
    fi
    
    # AI Service Auto Scaling Group
    local ai_service_asg_name=$(grep "AI_SERVICE_ASG_NAME=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    if [ -n "$ai_service_asg_name" ]; then
        local asg_instances=$(aws autoscaling describe-auto-scaling-groups \
            --auto-scaling-group-names "$ai_service_asg_name" \
            --query 'AutoScalingGroups[0].Instances | length' \
            --output text 2>/dev/null)
        
        if [ "$asg_instances" -gt 0 ]; then
            success "AI Service ASG has $asg_instances instances"
            increment_counters "PASS"
        else
            warning "AI Service ASG has no instances"
            increment_counters "FAIL"
        fi
    fi
}

# Validate Storage Resources
validate_storage() {
    log "Validating storage resources..."
    
    # Frontend Bucket
    local frontend_bucket=$(grep "FRONTEND_BUCKET=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    if [ -n "$frontend_bucket" ]; then
        local bucket_exists=$(aws s3 ls "s3://$frontend_bucket" 2>/dev/null && echo "exists" || echo "")
        if [ -n "$bucket_exists" ]; then
            success "Frontend bucket exists: $frontend_bucket"
            increment_counters "PASS"
        else
            error_exit "Frontend bucket not found: $frontend_bucket"
            increment_counters "FAIL"
        fi
    fi
    
    # Media Bucket
    local media_bucket=$(grep "MEDIA_BUCKET=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    if [ -n "$media_bucket" ]; then
        local bucket_exists=$(aws s3 ls "s3://$media_bucket" 2>/dev/null && echo "exists" || echo "")
        if [ -n "$bucket_exists" ]; then
            success "Media bucket exists: $media_bucket"
            increment_counters "PASS"
        else
            error_exit "Media bucket not found: $media_bucket"
            increment_counters "FAIL"
        fi
    fi
    
    # Logs Bucket
    local logs_bucket=$(grep "LOGS_BUCKET=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    if [ -n "$logs_bucket" ]; then
        local bucket_exists=$(aws s3 ls "s3://$logs_bucket" 2>/dev/null && echo "exists" || echo "")
        if [ -n "$bucket_exists" ]; then
            success "Logs bucket exists: $logs_bucket"
            increment_counters "PASS"
        else
            error_exit "Logs bucket not found: $logs_bucket"
            increment_counters "FAIL"
        fi
    fi
}

# Validate Networking Resources
validate_networking() {
    log "Validating networking resources..."
    
    # API Gateway
    local api_id=$(grep "API_GATEWAY_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    if [ -n "$api_id" ]; then
        local api_name=$(aws apigateway get-rest-api \
            --rest-api-id "$api_id" \
            --query 'name' \
            --output text 2>/dev/null)
        
        if [ -n "$api_name" ]; then
            local api_url=$(grep "API_GATEWAY_URL=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
            success "API Gateway exists: $api_name ($api_url)"
            increment_counters "PASS"
        else
            error_exit "API Gateway not found"
            increment_counters "FAIL"
        fi
    fi
    
    # SQS Queues
    local user_events_queue_url=$(grep "USER_EVENTS_QUEUE_URL=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    if [ -n "$user_events_queue_url" ]; then
        local queue_attrs=$(aws sqs get-queue-attributes \
            --queue-url "$user_events_queue_url" \
            --attribute-names QueueArn \
            --query 'Attributes.QueueArn' \
            --output text 2>/dev/null)
        
        if [ -n "$queue_attrs" ]; then
            success "User events SQS queue exists"
            increment_counters "PASS"
        else
            error_exit "User events SQS queue not found"
            increment_counters "FAIL"
        fi
    fi
    
    # SNS Topics
    local system_events_topic_arn=$(grep "SYSTEM_EVENTS_TOPIC_ARN=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    if [ -n "$system_events_topic_arn" ]; then
        local topic_attrs=$(aws sns get-topic-attributes \
            --topic-arn "$system_events_topic_arn" \
            --query 'Attributes.TopicArn' \
            --output text 2>/dev/null)
        
        if [ -n "$topic_attrs" ]; then
            success "System events SNS topic exists"
            increment_counters "PASS"
        else
            error_exit "System events SNS topic not found"
            increment_counters "FAIL"
        fi
    fi
}

# Validate Monitoring Resources
validate_monitoring() {
    log "Validating monitoring resources..."
    
    # CloudWatch Log Groups
    local log_groups=($(jq -r '.monitoring.log_groups[]' "$CONFIG_FILE"))
    for log_group in "${log_groups[@]}"; do
        local log_group_exists=$(aws logs describe-log-groups \
            --log-group-name-prefix "$log_group" \
            --query 'logGroups[0].logGroupName' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$log_group_exists" ] && [ "$log_group_exists" != "None" ]; then
            success "Log group exists: $log_group"
            increment_counters "PASS"
        else
            error_exit "Log group not found: $log_group"
            increment_counters "FAIL"
        fi
    done
    
    # CloudWatch Dashboard
    local dashboard_name=$(grep "DASHBOARD_NAME=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    if [ -n "$dashboard_name" ]; then
        local dashboard_exists=$(aws cloudwatch get-dashboard \
            --dashboard-name "$dashboard_name" \
            --query 'DashboardBody' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$dashboard_exists" ]; then
            success "CloudWatch dashboard exists: $dashboard_name"
            increment_counters "PASS"
        else
            error_exit "CloudWatch dashboard not found"
            increment_counters "FAIL"
        fi
    fi
}

# Generate Validation Report
generate_report() {
    echo "=========================================="
    echo "SmartTrip Infrastructure Validation Report"
    echo "=========================================="
    echo "Date: $(date)"
    echo "Project: $(jq -r '.project.name' "$CONFIG_FILE")"
    echo "Environment: $(jq -r '.project.environment' "$CONFIG_FILE")"
    echo "=========================================="
    echo "Validation Summary:"
    echo "Total Checks: $TOTAL_CHECKS"
    echo "Passed: $PASSED_CHECKS"
    echo "Failed: $FAILED_CHECKS"
    
    if [ $FAILED_CHECKS -eq 0 ]; then
        echo "Status: ALL CHECKS PASSED"
        success "Infrastructure validation completed successfully!"
    else
        echo "Status: SOME CHECKS FAILED"
        warning "Please review failed checks and fix issues"
    fi
    
    echo "=========================================="
    
    # Resource Summary
    echo "Created Resources:"
    echo "------------------------------------------"
    
    # Core Infrastructure
    local vpc_id=$(grep "VPC_ID=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
    if [ -n "$vpc_id" ]; then
        echo "VPC: $vpc_id"
    fi
    
    # Databases
    local backend_db_id=$(grep "BACKEND_DB_ID=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
    local ai_service_db_id=$(grep "AI_SERVICE_DB_ID=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
    if [ -n "$backend_db_id" ]; then
        echo "Backend Database: $backend_db_id"
    fi
    if [ -n "$ai_service_db_id" ]; then
        echo "AI Service Database: $ai_service_db_id"
    fi
    
    # Load Balancer
    local lb_dns=$(grep "Load Balancer DNS:" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d' -f2)
    if [ -n "$lb_dns" ]; then
        echo "Load Balancer: $lb_dns"
    fi
    
    # Storage
    local frontend_bucket=$(grep "FRONTEND_BUCKET=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
    if [ -n "$frontend_bucket" ]; then
        echo "Frontend Bucket: $frontend_bucket"
    fi
    
    # API Gateway
    local api_url=$(grep "API_GATEWAY_URL=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
    if [ -n "$api_url" ]; then
        echo "API Gateway: $api_url"
    fi
    
    echo "=========================================="
    
    # Service Endpoints
    echo "Service Endpoints:"
    echo "------------------------------------------"
    
    if [ -n "$lb_dns" ]; then
        echo "Backend Service: http://$lb_dns:8080"
        echo "AI Service: http://$lb_dns:8000"
    fi
    
    if [ -n "$frontend_bucket" ]; then
        echo "Frontend Website: http://$frontend_bucket.s3-website-us-east-1.amazonaws.com"
    fi
    
    if [ -n "$api_url" ]; then
        echo "Backend API: $api_url/backend"
        echo "AI Service API: $api_url/ai"
    fi
    
    echo "=========================================="
    
    # Database Connections
    echo "Database Connections:"
    echo "------------------------------------------"
    
    local backend_db_endpoint=$(grep "BACKEND_DB_ENDPOINT=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
    local ai_service_db_endpoint=$(grep "AI_SERVICE_DB_ENDPOINT=" "$RESOURCE_IDS_FILE" 2>/dev/null | cut -d'=' -f2)
    
    if [ -n "$backend_db_endpoint" ]; then
        echo "Backend DB: $backend_db_endpoint:5432"
    fi
    
    if [ -n "$ai_service_db_endpoint" ]; then
        echo "AI Service DB: $ai_service_db_endpoint:5432"
    fi
    
    echo "=========================================="
}

# Main validation execution
main() {
    log "Starting infrastructure validation..."
    
    # Check if resource IDs file exists
    if [ ! -f "$RESOURCE_IDS_FILE" ]; then
        error_exit "Resource IDs file not found. Please run infrastructure setup first."
    fi
    
    # Run all validations
    validate_vpc
    validate_security_groups
    validate_databases
    validate_compute
    validate_storage
    validate_networking
    validate_monitoring
    
    # Generate final report
    generate_report
    
    # Exit with appropriate code
    if [ $FAILED_CHECKS -eq 0 ]; then
        exit 0
    else
        exit 1
    fi
}

# Execute main function
main "$@"
