#!/bin/bash
# Monitoring Setup Script for SmartTrip Infrastructure
# Creates CloudWatch log groups, metrics, and alarms

set -e

# Source configuration and utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"

# Resource ID storage
RESOURCE_IDS_FILE="$SCRIPT_DIR/resource-ids.txt"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Monitoring Setup - $1" | tee -a "$SCRIPT_DIR/infrastructure-setup.log"
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

# Create CloudWatch Log Groups
create_log_groups() {
    log "Creating CloudWatch log groups..."
    
    local project_name=$(jq -r '.project.name' "$CONFIG_FILE")
    
    # Get log group names from config
    local log_groups=($(jq -r '.monitoring.log_groups[]' "$CONFIG_FILE"))
    
    for log_group in "${log_groups[@]}"; do
        log "Creating log group: $log_group"
        
        # Check if log group already exists
        local log_group_exists=$(aws logs describe-log-groups \
            --log-group-name-prefix "$log_group" \
            --query 'logGroups[0].logGroupName' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$log_group_exists" ] && [ "$log_group_exists" != "None" ]; then
            warning "Log group $log_group already exists"
            echo "${log_group^^}_LOG_GROUP=$log_group" >> "$RESOURCE_IDS_FILE"
            continue
        fi
        
        # Create log group
        aws logs create-log-group \
            --log-group-name "$log_group" \
            --tags Key=Name,Value="$log_group" Key=Project,Value="$project_name" || error_exit "Failed to create log group: $log_group"
        
        # Set retention policy (14 days)
        aws logs put-retention-policy \
            --log-group-name "$log_group" \
            --retention-in-days 14 || warning "Failed to set retention policy for: $log_group"
        
        echo "${log_group^^}_LOG_GROUP=$log_group" >> "$RESOURCE_IDS_FILE"
        success "Log group created: $log_group"
    done
}

# Create CloudWatch Metric Alarms for EC2 Instances
create_ec2_alarms() {
    log "Creating CloudWatch alarms for EC2 instances..."
    
    local project_name=$(jq -r '.project.name' "$CONFIG_FILE")
    local cpu_high_threshold=$(jq -r '.monitoring.alarms.cpu_high_threshold' "$CONFIG_FILE")
    local cpu_low_threshold=$(jq -r '.monitoring.alarms.cpu_low_threshold' "$CONFIG_FILE")
    
    # Get backend ASG name
    local backend_asg_name=$(grep "BACKEND_ASG_NAME=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local ai_service_asg_name=$(grep "AI_SERVICE_ASG_NAME=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    
    # Backend CPU High Alarm
    aws cloudwatch put-metric-alarm \
        --alarm-name "$project_name-backend-cpu-high" \
        --alarm-description "Backend service CPU utilization is too high" \
        --metric-name CPUUtilization \
        --namespace AWS/EC2 \
        --statistic Average \
        --period 300 \
        --evaluation-periods 2 \
        --threshold "$cpu_high_threshold" \
        --comparison-operator GreaterThanThreshold \
        --dimensions Name=AutoScalingGroupName,Value="$backend_asg_name" \
        --alarm-actions "$(aws sns list-topics --query 'Topics[?contains(TopicArn, `system-events`)].TopicArn' --output text)" || warning "Failed to create backend CPU high alarm"
    
    # Backend CPU Low Alarm
    aws cloudwatch put-metric-alarm \
        --alarm-name "$project_name-backend-cpu-low" \
        --alarm-description "Backend service CPU utilization is too low" \
        --metric-name CPUUtilization \
        --namespace AWS/EC2 \
        --statistic Average \
        --period 300 \
        --evaluation-periods 2 \
        --threshold "$cpu_low_threshold" \
        --comparison-operator LessThanThreshold \
        --dimensions Name=AutoScalingGroupName,Value="$backend_asg_name" \
        --alarm-actions "$(aws sns list-topics --query 'Topics[?contains(TopicArn, `system-events`)].TopicArn' --output text)" || warning "Failed to create backend CPU low alarm"
    
    # AI Service CPU High Alarm
    aws cloudwatch put-metric-alarm \
        --alarm-name "$project_name-ai-service-cpu-high" \
        --alarm-description "AI service CPU utilization is too high" \
        --metric-name CPUUtilization \
        --namespace AWS/EC2 \
        --statistic Average \
        --period 300 \
        --evaluation-periods 2 \
        --threshold "$cpu_high_threshold" \
        --comparison-operator GreaterThanThreshold \
        --dimensions Name=AutoScalingGroupName,Value="$ai_service_asg_name" \
        --alarm-actions "$(aws sns list-topics --query 'Topics[?contains(TopicArn, `system-events`)].TopicArn' --output text)" || warning "Failed to create AI service CPU high alarm"
    
    # AI Service CPU Low Alarm
    aws cloudwatch put-metric-alarm \
        --alarm-name "$project_name-ai-service-cpu-low" \
        --alarm-description "AI service CPU utilization is too low" \
        --metric-name CPUUtilization \
        --namespace AWS/EC2 \
        --statistic Average \
        --period 300 \
        --evaluation-periods 2 \
        --threshold "$cpu_low_threshold" \
        --comparison-operator LessThanThreshold \
        --dimensions Name=AutoScalingGroupName,Value="$ai_service_asg_name" \
        --alarm-actions "$(aws sns list-topics --query 'Topics[?contains(TopicArn, `system-events`)].TopicArn' --output text)" || warning "Failed to create AI service CPU low alarm"
    
    success "EC2 CPU alarms created"
}

# Create CloudWatch Metric Alarms for RDS Instances
create_rds_alarms() {
    log "Creating CloudWatch alarms for RDS instances..."
    
    local project_name=$(jq -r '.project.name' "$CONFIG_FILE")
    
    # Get database identifiers
    local backend_db_id=$(grep "BACKEND_DB_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local ai_service_db_id=$(grep "AI_SERVICE_DB_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    
    # Backend Database CPU Alarm
    aws cloudwatch put-metric-alarm \
        --alarm-name "$project_name-backend-db-cpu" \
        --alarm-description "Backend database CPU utilization is high" \
        --metric-name CPUUtilization \
        --namespace AWS/RDS \
        --statistic Average \
        --period 300 \
        --evaluation-periods 2 \
        --threshold 80 \
        --comparison-operator GreaterThanThreshold \
        --dimensions Name=DBInstanceIdentifier,Value="$backend_db_id" \
        --alarm-actions "$(aws sns list-topics --query 'Topics[?contains(TopicArn, `system-events`)].TopicArn' --output text)" || warning "Failed to create backend DB CPU alarm"
    
    # Backend Database Connections Alarm
    aws cloudwatch put-metric-alarm \
        --alarm-name "$project_name-backend-db-connections" \
        --alarm-description "Backend database has too many connections" \
        --metric-name DatabaseConnections \
        --namespace AWS/RDS \
        --statistic Average \
        --period 300 \
        --evaluation-periods 2 \
        --threshold 50 \
        --comparison-operator GreaterThanThreshold \
        --dimensions Name=DBInstanceIdentifier,Value="$backend_db_id" \
        --alarm-actions "$(aws sns list-topics --query 'Topics[?contains(TopicArn, `system-events`)].TopicArn' --output text)" || warning "Failed to create backend DB connections alarm"
    
    # AI Service Database CPU Alarm
    aws cloudwatch put-metric-alarm \
        --alarm-name "$project_name-ai-service-db-cpu" \
        --alarm-description "AI service database CPU utilization is high" \
        --metric-name CPUUtilization \
        --namespace AWS/RDS \
        --statistic Average \
        --period 300 \
        --evaluation-periods 2 \
        --threshold 80 \
        --comparison-operator GreaterThanThreshold \
        --dimensions Name=DBInstanceIdentifier,Value="$ai_service_db_id" \
        --alarm-actions "$(aws sns list-topics --query 'Topics[?contains(TopicArn, `system-events`)].TopicArn' --output text)" || warning "Failed to create AI service DB CPU alarm"
    
    success "RDS alarms created"
}

# Create CloudWatch Metric Alarms for SQS Queues
create_sqs_alarms() {
    log "Creating CloudWatch alarms for SQS queues..."
    
    local project_name=$(jq -r '.project.name' "$CONFIG_FILE")
    local queue_depth_threshold=$(jq -r '.monitoring.alarms.queue_depth_threshold' "$CONFIG_FILE")
    
    # Get queue URLs
    local user_events_queue_url=$(grep "USER_EVENTS_QUEUE_URL=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local recommendation_events_queue_url=$(grep "RECOMMENDATION_EVENTS_QUEUE_URL=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local analytics_events_queue_url=$(grep "ANALYTICS_EVENTS_QUEUE_URL=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    
    # Get queue names from URLs
    local user_events_queue_name=$(basename "$user_events_queue_url")
    local recommendation_events_queue_name=$(basename "$recommendation_events_queue_url")
    local analytics_events_queue_name=$(basename "$analytics_events_queue_url")
    
    # User Events Queue Depth Alarm
    aws cloudwatch put-metric-alarm \
        --alarm-name "$project_name-user-events-queue-depth" \
        --alarm-description "User events queue depth is too high" \
        --metric-name ApproximateNumberOfMessagesVisible \
        --namespace AWS/SQS \
        --statistic Average \
        --period 300 \
        --evaluation-periods 2 \
        --threshold "$queue_depth_threshold" \
        --comparison-operator GreaterThanThreshold \
        --dimensions Name=QueueName,Value="$user_events_queue_name" \
        --alarm-actions "$(aws sns list-topics --query 'Topics[?contains(TopicArn, `system-events`)].TopicArn' --output text)" || warning "Failed to create user events queue depth alarm"
    
    # Recommendation Events Queue Depth Alarm
    aws cloudwatch put-metric-alarm \
        --alarm-name "$project_name-recommendation-events-queue-depth" \
        --alarm-description "Recommendation events queue depth is too high" \
        --metric-name ApproximateNumberOfMessagesVisible \
        --namespace AWS/SQS \
        --statistic Average \
        --period 300 \
        --evaluation-periods 2 \
        --threshold "$queue_depth_threshold" \
        --comparison-operator GreaterThanThreshold \
        --dimensions Name=QueueName,Value="$recommendation_events_queue_name" \
        --alarm-actions "$(aws sns list-topics --query 'Topics[?contains(TopicArn, `system-events`)].TopicArn' --output text)" || warning "Failed to create recommendation events queue depth alarm"
    
    success "SQS alarms created"
}

# Create CloudWatch Dashboard
create_dashboard() {
    log "Creating CloudWatch dashboard..."
    
    local project_name=$(jq -r '.project.name' "$CONFIG_FILE")
    
    # Get system events topic ARN for alarm actions
    local system_events_topic_arn=$(grep "SYSTEM_EVENTS_TOPIC_ARN=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    
    # Create dashboard JSON
    local dashboard_body='{
        "widgets": [
            {
                "type": "metric",
                "properties": {
                    "metrics": [
                        ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", "'$(grep "BACKEND_ASG_NAME=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)'"],
                        [".", ".", ".", "'$(grep "AI_SERVICE_ASG_NAME=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)'"]
                    ],
                    "period": 300,
                    "stat": "Average",
                    "region": "us-east-1",
                    "title": "EC2 CPU Utilization",
                    "yAxis": {"left": {"min": 0, "max": 100}}
                }
            },
            {
                "type": "metric",
                "properties": {
                    "metrics": [
                        ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", "'$(grep "BACKEND_DB_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)'"],
                        [".", ".", ".", "'$(grep "AI_SERVICE_DB_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)'"]
                    ],
                    "period": 300,
                    "stat": "Average",
                    "region": "us-east-1",
                    "title": "RDS CPU Utilization",
                    "yAxis": {"left": {"min": 0, "max": 100}}
                }
            },
            {
                "type": "metric",
                "properties": {
                    "metrics": [
                        ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "'$(basename $(grep "USER_EVENTS_QUEUE_URL=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2))'"],
                        [".", ".", ".", "'$(basename $(grep "RECOMMENDATION_EVENTS_QUEUE_URL=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2))'"],
                        [".", ".", ".", "'$(basename $(grep "ANALYTICS_EVENTS_QUEUE_URL=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2))'"]
                    ],
                    "period": 300,
                    "stat": "Average",
                    "region": "us-east-1",
                    "title": "SQS Queue Depth",
                    "yAxis": {"left": {"min": 0}}
                }
            },
            {
                "type": "log",
                "properties": {
                    "query": "SOURCE '$(grep "SMARTTRIP_APPLICATION_LOG_GROUP=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)' | fields @timestamp, @message | sort @timestamp desc | limit 20",
                    "region": "us-east-1",
                    "title": "Application Logs",
                    "view": "table"
                }
            }
        ]
    }'
    
    # Create dashboard
    aws cloudwatch put-dashboard \
        --dashboard-name "$project_name-dashboard" \
        --dashboard-body "$dashboard_body" || warning "Failed to create CloudWatch dashboard"
    
    echo "DASHBOARD_NAME=$project_name-dashboard" >> "$RESOURCE_IDS_FILE"
    success "CloudWatch dashboard created: $project_name-dashboard"
}

# Setup All Monitoring Resources
setup_monitoring_resources() {
    log "Setting up monitoring resources..."
    
    # Check if required resources exist
    if ! grep -q "BACKEND_ASG_NAME=" "$RESOURCE_IDS_FILE"; then
        error_exit "Backend ASG not found. Please run setup-compute.sh first."
    fi
    
    if ! grep -q "SYSTEM_EVENTS_TOPIC_ARN=" "$RESOURCE_IDS_FILE"; then
        error_exit "System events topic not found. Please run setup-networking.sh first."
    fi
    
    create_log_groups
    create_ec2_alarms
    create_rds_alarms
    create_sqs_alarms
    create_dashboard
}

# Validate Monitoring Setup
validate_monitoring_setup() {
    log "Validating monitoring setup..."
    
    local dashboard_name=$(grep "DASHBOARD_NAME=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    
    # Check dashboard
    local dashboard_exists=$(aws cloudwatch get-dashboard \
        --dashboard-name "$dashboard_name" \
        --query 'DashboardBody' \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$dashboard_exists" ]; then
        success "CloudWatch dashboard is accessible: $dashboard_name"
    else
        warning "CloudWatch dashboard not accessible"
    fi
    
    # Check log groups
    local application_log_group=$(grep "SMARTTRIP_APPLICATION_LOG_GROUP=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local log_group_exists=$(aws logs describe-log-groups \
        --log-group-name-prefix "$application_log_group" \
        --query 'logGroups[0].logGroupName' \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$log_group_exists" ] && [ "$log_group_exists" != "None" ]; then
        success "Log groups are accessible"
    else
        warning "Log groups not accessible"
    fi
    
    # Check alarms
    local alarm_count=$(aws cloudwatch describe-alarms \
        --alarm-name-prefix "$(jq -r '.project.name' "$CONFIG_FILE")" \
        --query 'MetricAlarms | length' \
        --output text 2>/dev/null || echo "0")
    
    log "Created $alarm_count CloudWatch alarms"
}

# Main execution
main() {
    log "Starting monitoring setup..."
    
    # Check if resource IDs file exists
    if [ ! -f "$RESOURCE_IDS_FILE" ]; then
        error_exit "Resource IDs file not found. Please run previous setup scripts first."
    fi
    
    setup_monitoring_resources
    validate_monitoring_setup
    
    success "Monitoring setup completed successfully!"
    
    # Display created resources
    echo "=========================================="
    echo "Monitoring Resources Created:"
    echo "=========================================="
    grep -E "(LOG_GROUP|DASHBOARD)" "$RESOURCE_IDS_FILE"
    echo "=========================================="
    
    echo "Monitoring Dashboard:"
    echo "CloudWatch Dashboard: $dashboard_name"
    echo "Region: us-east-1"
    echo "=========================================="
}

# Execute main function
main "$@"
