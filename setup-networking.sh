#!/bin/bash
# Networking Setup Script for SmartTrip Infrastructure
# Creates API Gateway, SQS queues, and SNS topics for microservice communication

set -e

# Source configuration and utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"

# Resource ID storage
RESOURCE_IDS_FILE="$SCRIPT_DIR/resource-ids.txt"

# Logging function
log() {
    echo "$(date "+%Y-%m-%d %H:%M:%S") - Networking Setup - $1" | tee -a "$SCRIPT_DIR/infrastructure-setup.log" >&2
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

# SQS no siempre respeta AWS_ENDPOINT_URL en el AWS CLI; LocalStack requiere --endpoint-url explícito.
aws_sqs() {
    if [ -n "${AWS_ENDPOINT_URL:-}" ]; then
        aws --endpoint-url "$AWS_ENDPOINT_URL" sqs "$@"
    else
        aws sqs "$@"
    fi
}

# Create API Gateway REST API
create_api_gateway() {
    log "Creating API Gateway REST API..."
    
    local project_name=$(jq -r '.project.name' "$CONFIG_FILE")
    local api_name=$(jq -r '.api_gateway.name' "$CONFIG_FILE")
    local api_description=$(jq -r '.api_gateway.description' "$CONFIG_FILE")
    
    # Create REST API
    local api_id=$(aws apigateway create-rest-api \
        --name "$api_name" \
        --description "$api_description" \
        --endpoint-configuration types=REGIONAL \
        --query 'id' \
        --output text 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$api_id" ]; then
        error_exit "Failed to create API Gateway REST API"
    fi
    
    echo "API_GATEWAY_ID=$api_id" >> "$RESOURCE_IDS_FILE"
    success "API Gateway REST API created: $api_id"
    
    echo "$api_id"
}

# Create API Gateway Resources
create_api_resources() {
    log "Creating API Gateway resources..."
    
    local api_id=$(grep "API_GATEWAY_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    
    # Root resource (path "/"), not items[0] (orden no garantizado)
    local root_resource_id=$(aws apigateway get-resources \
        --rest-api-id "$api_id" \
        --query "items[?path=='/'].id | [0]" \
        --output text 2>/dev/null)
    
    if [ -z "$root_resource_id" ]; then
        error_exit "Failed to get API Gateway root resource"
    fi
    
    echo "ROOT_RESOURCE_ID=$root_resource_id" >> "$RESOURCE_IDS_FILE"
    
    # Create backend resource
    local backend_resource_id=$(aws apigateway create-resource \
        --rest-api-id "$api_id" \
        --parent-id "$root_resource_id" \
        --path-part "backend" \
        --query 'id' \
        --output text 2>/dev/null)
    
    echo "BACKEND_RESOURCE_ID=$backend_resource_id" >> "$RESOURCE_IDS_FILE"
    success "Backend resource created: $backend_resource_id"
    
    # Create AI service resource
    local ai_service_resource_id=$(aws apigateway create-resource \
        --rest-api-id "$api_id" \
        --parent-id "$root_resource_id" \
        --path-part "ai" \
        --query 'id' \
        --output text 2>/dev/null)
    
    echo "AI_SERVICE_RESOURCE_ID=$ai_service_resource_id" >> "$RESOURCE_IDS_FILE"
    success "AI service resource created: $ai_service_resource_id"

    # Greedy proxy: /backend/{proxy+} y /ai/{proxy+} → reenvío a /api/v1/{proxy} en cada puerto del ALB
    local backend_proxy_id=$(aws apigateway create-resource \
        --rest-api-id "$api_id" \
        --parent-id "$backend_resource_id" \
        --path-part "{proxy+}" \
        --query 'id' \
        --output text 2>/dev/null) || error_exit "Failed to create backend {proxy+} resource"
    echo "BACKEND_PROXY_RESOURCE_ID=$backend_proxy_id" >> "$RESOURCE_IDS_FILE"
    success "Backend greedy proxy resource created: $backend_proxy_id"

    local ai_proxy_id=$(aws apigateway create-resource \
        --rest-api-id "$api_id" \
        --parent-id "$ai_service_resource_id" \
        --path-part "{proxy+}" \
        --query 'id' \
        --output text 2>/dev/null) || error_exit "Failed to create AI {proxy+} resource"
    echo "AI_PROXY_RESOURCE_ID=$ai_proxy_id" >> "$RESOURCE_IDS_FILE"
    success "AI greedy proxy resource created: $ai_proxy_id"

    echo "$root_resource_id $backend_resource_id $ai_service_resource_id"
}

# Create API Gateway Methods and Integrations
# HTTP_PROXY + ANY: reenvía todos los métodos y rutas bajo /api/v1 hacia el ALB (REST según API-ENDPOINTS.md).
# WebSocket (p. ej. /api/v1/ws-chat) no puede pasar por REST API Gateway; el cliente debe usar el ALB :8080 directo.
create_api_methods() {
    log "Creating API Gateway methods and integrations (HTTP_PROXY ANY + greedy {proxy+})..."
    
    local api_id=$(grep "API_GATEWAY_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local backend_proxy_id=$(grep "BACKEND_PROXY_RESOURCE_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local ai_proxy_id=$(grep "AI_PROXY_RESOURCE_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    
    # Get load balancer DNS name
    local lb_dns=$(grep "Load Balancer DNS:" "$RESOURCE_IDS_FILE" | awk -F': ' '{print $2}' || echo "")
    if [ -z "$lb_dns" ]; then
        error_exit "Load Balancer DNS not found. Please run setup-compute.sh first."
    fi
    if [ -z "$backend_proxy_id" ] || [ -z "$ai_proxy_id" ]; then
        error_exit "BACKEND_PROXY_RESOURCE_ID / AI_PROXY_RESOURCE_ID missing. create_api_resources must create {proxy+}."
    fi
    
    # Backend: GET https://.../stage/backend/users/login → http://lb:8080/api/v1/users/login
    aws apigateway put-method \
        --rest-api-id "$api_id" \
        --resource-id "$backend_proxy_id" \
        --http-method ANY \
        --authorization-type "NONE" \
        --request-parameters "method.request.path.proxy=true" \
        || error_exit "Failed to create backend ANY method"

    aws apigateway put-integration \
        --rest-api-id "$api_id" \
        --resource-id "$backend_proxy_id" \
        --http-method ANY \
        --type HTTP_PROXY \
        --integration-http-method ANY \
        --uri "http://${lb_dns}:8080/api/v1/{proxy}" \
        --request-parameters "integration.request.path.proxy=method.request.path.proxy" \
        --connection-type INTERNET \
        || error_exit "Failed to create backend HTTP_PROXY integration"

    # IA: GET https://.../stage/ai/recommendations/... → http://lb:8000/api/v1/recommendations/...
    aws apigateway put-method \
        --rest-api-id "$api_id" \
        --resource-id "$ai_proxy_id" \
        --http-method ANY \
        --authorization-type "NONE" \
        --request-parameters "method.request.path.proxy=true" \
        || error_exit "Failed to create AI ANY method"

    aws apigateway put-integration \
        --rest-api-id "$api_id" \
        --resource-id "$ai_proxy_id" \
        --http-method ANY \
        --type HTTP_PROXY \
        --integration-http-method ANY \
        --uri "http://${lb_dns}:8000/api/v1/{proxy}" \
        --request-parameters "integration.request.path.proxy=method.request.path.proxy" \
        --connection-type INTERNET \
        || error_exit "Failed to create AI HTTP_PROXY integration"

    success "API Gateway proxy integrations created (ANY → ALB :8080 / :8000 + /api/v1)"
}

# Deploy API Gateway
deploy_api_gateway() {
    log "Deploying API Gateway..."
    
    local api_id=$(grep "API_GATEWAY_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local stage_name=$(jq -r '.api_gateway.stage_name' "$CONFIG_FILE")
    
    # Create deployment
    local deployment_id=$(aws apigateway create-deployment \
        --rest-api-id "$api_id" \
        --stage-name "$stage_name" \
        --description "Initial deployment" \
        --query 'id' \
        --output text 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$deployment_id" ]; then
        error_exit "Failed to create API Gateway deployment"
    fi
    
    echo "API_DEPLOYMENT_ID=$deployment_id" >> "$RESOURCE_IDS_FILE"
    echo "API_STAGE_NAME=$stage_name" >> "$RESOURCE_IDS_FILE"
    
    # Get API Gateway URL
    local api_url="https://$api_id.execute-api.us-east-1.amazonaws.com/$stage_name"
    echo "API_GATEWAY_URL=$api_url" >> "$RESOURCE_IDS_FILE"
    
    success "API Gateway deployed: $api_url"
}

# Create SQS Queues
create_sqs_queues() {
    log "Creating SQS queues..."
    
    local project_name=$(jq -r '.project.name' "$CONFIG_FILE")
    
    # Get queue names from config
    local user_events_queue=$(jq -r '.message_queues.user_events_queue' "$CONFIG_FILE")
    local recommendation_events_queue=$(jq -r '.message_queues.recommendation_events_queue' "$CONFIG_FILE")
    local analytics_events_queue=$(jq -r '.message_queues.analytics_events_queue' "$CONFIG_FILE")
    
    # Create user events queue
    local user_events_queue_url=$(aws_sqs create-queue \
        --queue-name "$user_events_queue" \
        --attributes VisibilityTimeout=300,MessageRetentionPeriod=1209600 \
        --query 'QueueUrl' \
        --output text 2>/dev/null)
    
    local user_events_queue_arn=$(aws_sqs get-queue-attributes \
        --queue-url "$user_events_queue_url" \
        --attribute-names QueueArn \
        --query 'Attributes.QueueArn' \
        --output text 2>/dev/null)
    
    echo "USER_EVENTS_QUEUE_URL=$user_events_queue_url" >> "$RESOURCE_IDS_FILE"
    echo "USER_EVENTS_QUEUE_ARN=$user_events_queue_arn" >> "$RESOURCE_IDS_FILE"
    success "User events queue created: $user_events_queue"
    
    # Create recommendation events queue
    local recommendation_events_queue_url=$(aws_sqs create-queue \
        --queue-name "$recommendation_events_queue" \
        --attributes VisibilityTimeout=300,MessageRetentionPeriod=1209600 \
        --query 'QueueUrl' \
        --output text 2>/dev/null)
    
    local recommendation_events_queue_arn=$(aws_sqs get-queue-attributes \
        --queue-url "$recommendation_events_queue_url" \
        --attribute-names QueueArn \
        --query 'Attributes.QueueArn' \
        --output text 2>/dev/null)
    
    echo "RECOMMENDATION_EVENTS_QUEUE_URL=$recommendation_events_queue_url" >> "$RESOURCE_IDS_FILE"
    echo "RECOMMENDATION_EVENTS_QUEUE_ARN=$recommendation_events_queue_arn" >> "$RESOURCE_IDS_FILE"
    success "Recommendation events queue created: $recommendation_events_queue"
    
    # Create analytics events queue
    local analytics_events_queue_url=$(aws_sqs create-queue \
        --queue-name "$analytics_events_queue" \
        --attributes VisibilityTimeout=300,MessageRetentionPeriod=1209600 \
        --query 'QueueUrl' \
        --output text 2>/dev/null)
    
    local analytics_events_queue_arn=$(aws_sqs get-queue-attributes \
        --queue-url "$analytics_events_queue_url" \
        --attribute-names QueueArn \
        --query 'Attributes.QueueArn' \
        --output text 2>/dev/null)
    
    echo "ANALYTICS_EVENTS_QUEUE_URL=$analytics_events_queue_url" >> "$RESOURCE_IDS_FILE"
    echo "ANALYTICS_EVENTS_QUEUE_ARN=$analytics_events_queue_arn" >> "$RESOURCE_IDS_FILE"
    success "Analytics events queue created: $analytics_events_queue"
}

# Create SNS Topics
create_sns_topics() {
    log "Creating SNS topics..."
    
    local project_name=$(jq -r '.project.name' "$CONFIG_FILE")
    
    # Get topic names from config
    local user_events_topic=$(jq -r '.message_queues.user_events_topic' "$CONFIG_FILE")
    local recommendation_events_topic=$(jq -r '.message_queues.recommendation_events_topic' "$CONFIG_FILE")
    local system_events_topic=$(jq -r '.message_queues.system_events_topic' "$CONFIG_FILE")
    
    # Create user events topic
    local user_events_topic_arn=$(aws sns create-topic \
        --name "$user_events_topic" \
        --query 'TopicArn' \
        --output text 2>/dev/null)
    
    echo "USER_EVENTS_TOPIC_ARN=$user_events_topic_arn" >> "$RESOURCE_IDS_FILE"
    success "User events topic created: $user_events_topic"
    
    # Create recommendation events topic
    local recommendation_events_topic_arn=$(aws sns create-topic \
        --name "$recommendation_events_topic" \
        --query 'TopicArn' \
        --output text 2>/dev/null)
    
    echo "RECOMMENDATION_EVENTS_TOPIC_ARN=$recommendation_events_topic_arn" >> "$RESOURCE_IDS_FILE"
    success "Recommendation events topic created: $recommendation_events_topic"
    
    # Create system events topic
    local system_events_topic_arn=$(aws sns create-topic \
        --name "$system_events_topic" \
        --query 'TopicArn' \
        --output text 2>/dev/null)
    
    echo "SYSTEM_EVENTS_TOPIC_ARN=$system_events_topic_arn" >> "$RESOURCE_IDS_FILE"
    success "System events topic created: $system_events_topic"
}

# Create SNS Subscriptions
create_sns_subscriptions() {
    log "Creating SNS subscriptions..."
    
    local user_events_topic_arn=$(grep "USER_EVENTS_TOPIC_ARN=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local recommendation_events_topic_arn=$(grep "RECOMMENDATION_EVENTS_TOPIC_ARN=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local system_events_topic_arn=$(grep "SYSTEM_EVENTS_TOPIC_ARN=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    
    local recommendation_events_queue_arn=$(grep "RECOMMENDATION_EVENTS_QUEUE_ARN=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local analytics_events_queue_arn=$(grep "ANALYTICS_EVENTS_QUEUE_ARN=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    
    # Subscribe AI service to user events topic
    aws sns subscribe \
        --topic-arn "$user_events_topic_arn" \
        --protocol sqs \
        --notification-endpoint "$recommendation_events_queue_arn" || warning "Failed to subscribe AI service to user events"
    
    # Subscribe backend to recommendation events topic
    aws sns subscribe \
        --topic-arn "$recommendation_events_topic_arn" \
        --protocol sqs \
        --notification-endpoint "$analytics_events_queue_arn" || warning "Failed to subscribe backend to recommendation events"
    
    # Subscribe monitoring to system events topic
    aws sns subscribe \
        --topic-arn "$system_events_topic_arn" \
        --protocol sqs \
        --notification-endpoint "$analytics_events_queue_arn" || warning "Failed to subscribe monitoring to system events"
    
    success "SNS subscriptions created"
}

# Setup All Networking Resources
setup_networking_resources() {
    log "Setting up networking resources..."
    
    # Check if compute resources are available
    if ! grep -q "Load Balancer DNS:" "$RESOURCE_IDS_FILE"; then
        error_exit "Load Balancer not found. Please run setup-compute.sh first."
    fi
    
    create_api_gateway
    create_api_resources
    create_api_methods
    deploy_api_gateway
    create_sqs_queues
    create_sns_topics
    create_sns_subscriptions
}

# Validate Networking Setup
validate_networking_setup() {
    log "Validating networking setup..."
    
    local api_id=$(grep "API_GATEWAY_ID=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local api_url=$(grep "API_GATEWAY_URL=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    
    # Check API Gateway
    local api_status=$(aws apigateway get-rest-api \
        --rest-api-id "$api_id" \
        --query 'name' \
        --output text 2>/dev/null)
    
    if [ -n "$api_status" ]; then
        success "API Gateway is accessible: $api_url"
    else
        error_exit "API Gateway not accessible"
    fi
    
    # Check SQS queues
    local user_events_queue_url=$(grep "USER_EVENTS_QUEUE_URL=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local queue_status=$(aws_sqs get-queue-attributes \
        --queue-url "$user_events_queue_url" \
        --attribute-names ApproximateNumberOfMessages \
        --query 'Attributes.ApproximateNumberOfMessages' \
        --output text 2>/dev/null)
    
    if [ -n "$queue_status" ]; then
        success "SQS queues are accessible"
    else
        error_exit "SQS queues not accessible"
    fi
    
    # Check SNS topics
    local user_events_topic_arn=$(grep "USER_EVENTS_TOPIC_ARN=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local topic_status=$(aws sns get-topic-attributes \
        --topic-arn "$user_events_topic_arn" \
        --query 'Attributes.SubscriptionsConfirmed' \
        --output text 2>/dev/null)
    
    if [ -n "$topic_status" ]; then
        success "SNS topics are accessible"
    else
        error_exit "SNS topics not accessible"
    fi
}

# Main execution
main() {
    log "Starting networking setup..."
    
    # Check if resource IDs file exists
    if [ ! -f "$RESOURCE_IDS_FILE" ]; then
        error_exit "Resource IDs file not found. Please run setup-vpc.sh, setup-security.sh, setup-databases.sh, and setup-compute.sh first."
    fi
    
    setup_networking_resources
    validate_networking_setup
    
    success "Networking setup completed successfully!"
    
    # Display created resources
    echo "=========================================="
    echo "Networking Resources Created:"
    echo "=========================================="
    grep -E "(API_GATEWAY|QUEUE|TOPIC)" "$RESOURCE_IDS_FILE"
    echo "=========================================="
    
    echo "API Endpoints (REST vía API Gateway; prefijo /api/v1 lo añade el proxy hacia el ALB):"
    local api_url=$(grep "API_GATEWAY_URL=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    echo "Backend base:  $api_url/backend   → Spring :8080/api/v1/..."
    echo "AI base:       $api_url/ai         → FastAPI :8000/api/v1/..."
    echo "Ejemplo:       POST $api_url/backend/users/login"
    echo "WebSocket STOMP no usa API Gateway; usar ALB :8080 (p. ej. .../api/v1/ws-chat con SockJS)."
    echo "=========================================="
}

# Execute main function
main "$@"
