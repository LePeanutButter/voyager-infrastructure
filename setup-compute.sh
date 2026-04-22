#!/bin/bash
# Compute Setup Script for SmartTrip Infrastructure
# Creates EC2 instances, Auto Scaling Groups, and load balancers

set -e

# Source configuration and utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.json"

# Resource ID storage
RESOURCE_IDS_FILE="$SCRIPT_DIR/resource-ids.txt"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Compute Setup - $1" | tee -a "$SCRIPT_DIR/infrastructure-setup.log"
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

# Get network and security information
get_network_security_info() {
    local vpc_id=$(grep "VPC_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local backend_sg_id=$(grep "BACKEND_SG_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local ai_service_sg_id=$(grep "AI_SERVICE_SG_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local subnet_ids=()
    
    # Get subnet IDs
    local subnet_count=$(jq '.vpc.public_subnets | length' "$CONFIG_FILE")
    for ((i=0; i<subnet_count; i++)); do
        local subnet_id=$(grep "SUBNET_${i}_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
        subnet_ids+=("$subnet_id")
    done
    
    echo "$vpc_id $backend_sg_id $ai_service_sg_id ${subnet_ids[@]}"
}

# Create Launch Template
create_launch_template() {
    local service_name="$1"
    local compute_config="$2"
    local security_group_id="$3"
    local template_key="$4"
    
    log "Creating launch template for $service_name"
    
    local project_name=$(jq -r '.project.name' "$CONFIG_FILE")
    local instance_type=$(echo "$compute_config" | jq -r '.instance_type')
    local ami=$(echo "$compute_config" | jq -r '.ami')
    local key_name=$(echo "$compute_config" | jq -r '.key_name')
    
    # Create user data script
    local user_data_script=$(cat <<EOF
#!/bin/bash
# User data for $service_name instance

# Update system
yum update -y

# Install AWS CLI
yum install -y aws-cli

# Create application directory
mkdir -p /opt/$service_name

# Setup logging
mkdir -p /var/log/$service_name

# Create basic startup script
cat > /opt/$service_name/startup.sh << 'INTERNAL_EOF'
#!/bin/bash
echo "$service_name starting at \$(date)" >> /var/log/$service_name/startup.log
# Service startup logic will be added by CI/CD pipeline
INTERNAL_EOF

chmod +x /opt/$service_name/startup.sh

echo "Instance setup completed at \$(date)" >> /var/log/$service_name/setup.log
EOF
)
    
    # Create launch template
    local template_name="${project_name}-${service_name}-lt"
    
    local template_id=$(aws ec2 create-launch-template \
        --launch-template-name "$template_name" \
        --launch-template-data "{
            \"ImageId\": \"$ami\",
            \"InstanceType\": \"$instance_type\",
            \"KeyName\": \"$key_name\",
            \"SecurityGroupIds\": [\"$security_group_id\"],
            \"UserData\": \"$(echo "$user_data_script" | base64 -w 0)\",
            \"TagSpecifications\": [
                {
                    \"ResourceType\": \"instance\",
                    \"Tags\": [
                        {\"Key\": \"Name\", \"Value\": \"$project_name-$service_name\"},
                        {\"Key\": \"Project\", \"Value\": \"$project_name\"},
                        {\"Key\": \"Service\", \"Value\": \"$service_name\"}
                    ]
                }
            ]
        }" \
        --query 'LaunchTemplate.LaunchTemplateId' \
        --output text 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$template_id" ]; then
        error_exit "Failed to create launch template for $service_name"
    fi
    
    echo "$template_key=$template_id" >> "$RESOURCE_IDS_FILE"
    echo "${template_key}_NAME=$template_name" >> "$RESOURCE_IDS_FILE"
    success "Launch template created for $service_name: $template_id"
    
    echo "$template_id"
}

# Create Auto Scaling Group
create_auto_scaling_group() {
    local service_name="$1"
    local compute_config="$2"
    local launch_template_id="$3"
    local asg_key="$4"
    
    log "Creating Auto Scaling Group for $service_name"
    
    local project_name=$(jq -r '.project.name' "$CONFIG_FILE")
    local min_capacity=$(echo "$compute_config" | jq -r '.min_capacity')
    local max_capacity=$(echo "$compute_config" | jq -r '.max_capacity')
    local desired_capacity=$(echo "$compute_config" | jq -r '.desired_capacity')
    
    # Get subnet IDs
    local subnet_ids=()
    local subnet_count=$(jq '.vpc.public_subnets | length' "$CONFIG_FILE")
    for ((i=0; i<subnet_count; i++)); do
        local subnet_id=$(grep "SUBNET_${i}_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
        subnet_ids+=("$subnet_id")
    done
    
    local asg_name="${project_name}-${service_name}-asg"
    
    aws autoscaling create-auto-scaling-group \
        --auto-scaling-group-name "$asg_name" \
        --launch-template "LaunchTemplateId=$launch_template_id" \
        --min-size "$min_capacity" \
        --max-size "$max_capacity" \
        --desired-capacity "$desired_capacity" \
        --vpc-zone-identifier "${subnet_ids[@]}" \
        --health-check-type "EC2" \
        --health-check-grace-period 300 \
        --tag "Key=Name,Value=$project_name-$service_name,PropagateAtLaunch=true" \
        --tag "Key=Project,Value=$project_name,PropagateAtLaunch=true" \
        --tag "Key=Service,Value=$service_name,PropagateAtLaunch=true" || error_exit "Failed to create Auto Scaling Group for $service_name"
    
    echo "$asg_key=$asg_name" >> "$RESOURCE_IDS_FILE"
    success "Auto Scaling Group created for $service_name: $asg_name"
    
    echo "$asg_name"
}

# Create Load Balancer
create_load_balancer() {
    log "Creating Application Load Balancer"
    
    local project_name=$(jq -r '.project.name' "$CONFIG_FILE")
    
    # Get subnet IDs
    local subnet_ids=()
    local subnet_count=$(jq '.vpc.public_subnets | length' "$CONFIG_FILE")
    for ((i=0; i<subnet_count; i++)); do
        local subnet_id=$(grep "SUBNET_${i}_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
        subnet_ids+=("$subnet_id")
    done
    
    local lb_name="${project_name}-alb"
    
    local lb_arn=$(aws elbv2 create-load-balancer \
        --name "$lb_name" \
        --subnets "${subnet_ids[@]}" \
        --security-groups "$(grep "BACKEND_SG_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)" \
        --scheme "internet-facing" \
        --type "application" \
        --ip-address-type "ipv4" \
        --query 'LoadBalancers[0].LoadBalancerArn' \
        --output text 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$lb_arn" ]; then
        error_exit "Failed to create Load Balancer"
    fi
    
    echo "LB_ARN=$lb_arn" >> "$RESOURCE_IDS_FILE"
    echo "LB_NAME=$lb_name" >> "$RESOURCE_IDS_FILE"
    success "Load Balancer created: $lb_name"
    
    # Wait for load balancer to be available
    log "Waiting for Load Balancer to become available..."
    aws elbv2 wait load-balancer-available --load-balancer-arns "$lb_arn"
    
    echo "$lb_arn"
}

# Create Target Groups
create_target_groups() {
    log "Creating target groups"
    
    local project_name=$(jq -r '.project.name' "$CONFIG_FILE")
    local vpc_id=$(grep "VPC_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    
    # Backend target group
    local backend_tg_name="${project_name}-backend-tg"
    local backend_tg_arn=$(aws elbv2 create-target-group \
        --name "$backend_tg_name" \
        --protocol "HTTP" \
        --port 8080 \
        --vpc-id "$vpc_id" \
        --target-type "instance" \
        --health-check-protocol "HTTP" \
        --health-check-port "8081" \
        --health-check-path "/actuator/health" \
        --matcher "HttpCode=200" \
        --query 'TargetGroups[0].TargetGroupArn' \
        --output text 2>/dev/null)
    
    echo "BACKEND_TG_ARN=$backend_tg_arn" >> "$RESOURCE_IDS_FILE"
    success "Backend target group created: $backend_tg_name"
    
    # AI service target group
    local ai_tg_name="${project_name}-ai-service-tg"
    local ai_tg_arn=$(aws elbv2 create-target-group \
        --name "$ai_tg_name" \
        --protocol "HTTP" \
        --port 8000 \
        --vpc-id "$vpc_id" \
        --target-type "instance" \
        --health-check-protocol "HTTP" \
        --health-check-port "8001" \
        --health-check-path "/health" \
        --matcher "HttpCode=200" \
        --query 'TargetGroups[0].TargetGroupArn' \
        --output text 2>/dev/null)
    
    echo "AI_SERVICE_TG_ARN=$ai_tg_arn" >> "$RESOURCE_IDS_FILE"
    success "AI service target group created: $ai_tg_name"
    
    echo "$backend_tg_arn $ai_tg_arn"
}

# Create Load Balancer Listeners
create_listeners() {
    log "Creating load balancer listeners"
    
    local lb_arn=$(grep "LB_ARN=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local backend_tg_arn=$(grep "BACKEND_TG_ARN=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local ai_tg_arn=$(grep "AI_SERVICE_TG_ARN=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    
    # Backend listener (port 8080)
    aws elbv2 create-listener \
        --load-balancer-arn "$lb_arn" \
        --protocol "HTTP" \
        --port 8080 \
        --default-actions "Type=forward,TargetGroupArn=$backend_tg_arn" || error_exit "Failed to create backend listener"
    
    success "Backend listener created (port 8080)"
    
    # AI service listener (port 8000)
    aws elbv2 create-listener \
        --load-balancer-arn "$lb_arn" \
        --protocol "HTTP" \
        --port 8000 \
        --default-actions "Type=forward,TargetGroupArn=$ai_tg_arn" || error_exit "Failed to create AI service listener"
    
    success "AI service listener created (port 8000)"
}

# Attach Auto Scaling Groups to Target Groups
attach_asg_to_target_groups() {
    log "Attaching Auto Scaling Groups to target groups"
    
    local backend_asg_name=$(grep "BACKEND_ASG_NAME=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local ai_service_asg_name=$(grep "AI_SERVICE_ASG_NAME=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local backend_tg_arn=$(grep "BACKEND_TG_ARN=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local ai_service_tg_arn=$(grep "AI_SERVICE_TG_ARN=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    
    # Attach backend ASG to backend target group
    aws autoscaling attach-load-balancer-target-groups \
        --auto-scaling-group-name "$backend_asg_name" \
        --target-group-arns "$backend_tg_arn" || error_exit "Failed to attach backend ASG to target group"
    
    success "Backend ASG attached to target group"
    
    # Attach AI service ASG to AI service target group
    aws autoscaling attach-load-balancer-target-groups \
        --auto-scaling-group-name "$ai_service_asg_name" \
        --target-group-arns "$ai_service_tg_arn" || error_exit "Failed to attach AI service ASG to target group"
    
    success "AI service ASG attached to target group"
}

# Setup Compute Resources
setup_compute_resources() {
    log "Setting up compute resources..."
    
    # Get network and security info
    local network_info=($(get_network_security_info))
    local vpc_id="${network_info[0]}"
    local backend_sg_id="${network_info[1]}"
    local ai_service_sg_id="${network_info[2]}"
    
    # Create launch templates
    local backend_compute_config=$(jq '.compute.backend' "$CONFIG_FILE")
    local backend_lt_id=$(create_launch_template "backend" "$backend_compute_config" "$backend_sg_id" "BACKEND_LT_ID")
    
    local ai_compute_config=$(jq '.compute.ai_service' "$CONFIG_FILE")
    local ai_lt_id=$(create_launch_template "ai-service" "$ai_compute_config" "$ai_service_sg_id" "AI_SERVICE_LT_ID")
    
    # Create Auto Scaling Groups
    local backend_asg_name=$(create_auto_scaling_group "backend" "$backend_compute_config" "$backend_lt_id" "BACKEND_ASG_NAME")
    local ai_service_asg_name=$(create_auto_scaling_group "ai-service" "$ai_compute_config" "$ai_lt_id" "AI_SERVICE_ASG_NAME")
    
    # Create load balancer and target groups
    local lb_arn=$(create_load_balancer)
    local target_groups=($(create_target_groups))
    
    # Create listeners
    create_listeners
    
    # Attach ASGs to target groups
    attach_asg_to_target_groups
}

# Validate Compute Setup
validate_compute_setup() {
    log "Validating compute setup..."
    
    local lb_name=$(grep "LB_NAME=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    
    # Get load balancer DNS name
    local lb_dns=$(aws elbv2 describe-load-balancers \
        --names "$lb_name" \
        --query 'LoadBalancers[0].DNSName' \
        --output text 2>/dev/null)
    
    if [ -n "$lb_dns" ]; then
        success "Load Balancer is available: http://$lb_dns"
        echo "Load Balancer DNS: $lb_dns" >> "$RESOURCE_IDS_FILE"
        echo "Backend Service: http://$lb_dns:8080" >> "$RESOURCE_IDS_FILE"
        echo "AI Service: http://$lb_dns:8000" >> "$RESOURCE_IDS_FILE"
    else
        warning "Load Balancer DNS not available"
    fi
    
    # Check Auto Scaling Groups
    local backend_asg_name=$(grep "BACKEND_ASG_NAME=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local ai_service_asg_name=$(grep "AI_SERVICE_ASG_NAME=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    
    local backend_asg_status=$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$backend_asg_name" \
        --query 'AutoScalingGroups[0].Instances[0].LifecycleState' \
        --output text 2>/dev/null || echo "No instances")
    
    local ai_service_asg_status=$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$ai_service_asg_name" \
        --query 'AutoScalingGroups[0].Instances[0].LifecycleState' \
        --output text 2>/dev/null || echo "No instances")
    
    log "Backend ASG status: $backend_asg_status"
    log "AI Service ASG status: $ai_service_asg_status"
}

# Main execution
main() {
    log "Starting compute setup..."
    
    # Check if resource IDs file exists
    if [ ! -f "$RESOURCE_IDS_FILE" ]; then
        error_exit "Resource IDs file not found. Please run setup-vpc.sh, setup-security.sh, and setup-databases.sh first."
    fi
    
    setup_compute_resources
    validate_compute_setup
    
    success "Compute setup completed successfully!"
    
    # Display created resources
    echo "=========================================="
    echo "Compute Resources Created:"
    echo "=========================================="
    grep -E "(LT_ID|ASG_NAME|LB_ARN|TG_ARN)" "$RESOURCE_IDS_FILE"
    echo "=========================================="
    echo "Service Endpoints:"
    grep -E "(Backend Service|AI Service)" "$RESOURCE_IDS_FILE"
    echo "=========================================="
}

# Execute main function
main "$@"
