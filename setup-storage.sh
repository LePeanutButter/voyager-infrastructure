#!/bin/bash
# Storage Setup Script for SmartTrip Infrastructure
# Creates S3 buckets for frontend, media, and logs storage

set -e

# Source configuration and utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"

# Resource ID storage
RESOURCE_IDS_FILE="$SCRIPT_DIR/resource-ids.txt"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Storage Setup - $1" | tee -a "$SCRIPT_DIR/infrastructure-setup.log"
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

# Create S3 Bucket
create_s3_bucket() {
    local bucket_name="$1"
    local bucket_purpose="$2"
    local bucket_key="$3"
    
    log "Creating S3 bucket: $bucket_name for $bucket_purpose"
    
    local project_name=$(jq -r '.project.name' "$CONFIG_FILE")
    local region=$(jq -r '.project.region' "$CONFIG_FILE")
    
    # Check if bucket already exists
    local bucket_exists=$(aws s3 ls "s3://$bucket_name" 2>/dev/null || echo "")
    
    if [ -n "$bucket_exists" ]; then
        warning "S3 bucket $bucket_name already exists"
        echo "$bucket_key=$bucket_name" >> "$RESOURCE_IDS_FILE"
        return 0
    fi
    
    # Create S3 bucket
    if [ "$region" = "us-east-1" ]; then
        # us-east-1 doesn't support location constraint
        aws s3 mb "s3://$bucket_name" || error_exit "Failed to create S3 bucket: $bucket_name"
    else
        aws s3 mb "s3://$bucket_name" --region "$region" || error_exit "Failed to create S3 bucket: $bucket_name"
    fi
    
    # Add tags
    aws s3api put-bucket-tagging \
        --bucket "$bucket_name" \
        --tagging "TagSet=[{Key=Name,Value=$bucket_name},{Key=Project,Value=$project_name},{Key=Environment,Value=production},{Key=Purpose,Value=$bucket_purpose}]" || warning "Failed to tag bucket: $bucket_name"
    
    echo "$bucket_key=$bucket_name" >> "$RESOURCE_IDS_FILE"
    success "S3 bucket created: $bucket_name"
}

# Configure S3 Bucket for Static Website Hosting
configure_static_website() {
    local bucket_name="$1"
    
    log "Configuring S3 bucket for static website hosting: $bucket_name"
    
    # Enable static website hosting
    aws s3 website "s3://$bucket_name" \
        --index-document index.html \
        --error-document error.html || warning "Failed to configure static website for: $bucket_name"
    
    # Remove public access block configuration
    aws s3api put-public-access-block \
        --bucket "$bucket_name" \
        --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" || error_exit "Failed to update public access block for: $bucket_name"
    
    # Add bucket policy for public read access
    local bucket_policy='{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "PublicReadGetObject",
                "Effect": "Allow",
                "Principal": "*",
                "Action": "s3:GetObject",
                "Resource": "arn:aws:s3:::'$bucket_name'/*"
            }
        ]
    }'
    
    aws s3api put-bucket-policy --bucket "$bucket_name" --policy "$bucket_policy" || error_exit "Failed to set bucket policy for: $bucket_name"
    
    success "Static website hosting configured for: $bucket_name"
}

# Configure S3 Bucket for Private Storage
configure_private_storage() {
    local bucket_name="$1"
    local bucket_purpose="$2"
    
    log "Configuring S3 bucket for private storage: $bucket_name"
    
    # Ensure public access is blocked for private buckets
    aws s3api put-public-access-block \
        --bucket "$bucket_name" \
        --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=false,BlockPublicPolicy=true,RestrictPublicBuckets=true" || error_exit "Failed to update public access block for: $bucket_name"
    
    # Enable versioning for important buckets
    if [ "$bucket_purpose" = "logs" ] || [ "$bucket_purpose" = "media" ]; then
        aws s3api put-bucket-versioning \
            --bucket "$bucket_name" \
            --versioning-configuration Status=Enabled || warning "Failed to enable versioning for: $bucket_name"
    fi
    
    # Enable server-side encryption
    aws s3api put-bucket-encryption \
        --bucket "$bucket_name" \
        --server-side-encryption-configuration '{
            "Rules": [
                {
                    "ApplyServerSideEncryptionByDefault": {
                        "SSEAlgorithm": "AES256"
                    }
                }
            ]
        }' || warning "Failed to enable encryption for: $bucket_name"
    
    success "Private storage configured for: $bucket_name"
}

# Create Lifecycle Policy for Logs Bucket
create_lifecycle_policy() {
    local bucket_name="$1"
    
    log "Creating lifecycle policy for logs bucket: $bucket_name"
    
    local lifecycle_policy='{
        "Rules": [
            {
                "ID": "LogLifecycleRule",
                "Status": "Enabled",
                "Filter": {
                    "Prefix": "logs/"
                },
                "Transitions": [
                    {
                        "Days": 30,
                        "StorageClass": "STANDARD_IA"
                    },
                    {
                        "Days": 90,
                        "StorageClass": "GLACIER"
                    },
                    {
                        "Days": 365,
                        "StorageClass": "DEEP_ARCHIVE"
                    }
                ],
                "Expiration": {
                    "Days": 2555
                }
            }
        ]
    }'
    
    aws s3api put-bucket-lifecycle-configuration --bucket "$bucket_name" --lifecycle-configuration "$lifecycle_policy" || warning "Failed to set lifecycle policy for: $bucket_name"
    
    success "Lifecycle policy created for: $bucket_name"
}

# Setup All Storage Resources
setup_storage_resources() {
    log "Setting up storage resources..."
    
    local project_name=$(jq -r '.project.name' "$CONFIG_FILE")
    
    # Get bucket names from config
    local frontend_bucket=$(jq -r '.storage.frontend_bucket' "$CONFIG_FILE")
    local media_bucket=$(jq -r '.storage.media_bucket' "$CONFIG_FILE")
    local logs_bucket=$(jq -r '.storage.logs_bucket' "$CONFIG_FILE")
    
    # Create frontend bucket (static website)
    create_s3_bucket "$frontend_bucket" "frontend" "FRONTEND_BUCKET"
    configure_static_website "$frontend_bucket"
    
    # Create media bucket (private storage)
    create_s3_bucket "$media_bucket" "media" "MEDIA_BUCKET"
    configure_private_storage "$media_bucket" "media"
    
    # Create logs bucket (private storage with lifecycle)
    create_s3_bucket "$logs_bucket" "logs" "LOGS_BUCKET"
    configure_private_storage "$logs_bucket" "logs"
    create_lifecycle_policy "$logs_bucket"
    
    # Create sample directory structure
    log "Creating directory structure in buckets..."
    
    # Frontend bucket structure
    aws s3api put-object --bucket "$frontend_bucket" --key "index.html" --body /dev/null --content-type "text/html" || warning "Failed to create index.html placeholder"
    aws s3api put-object --bucket "$frontend_bucket" --key "error.html" --body /dev/null --content-type "text/html" || warning "Failed to create error.html placeholder"
    
    # Media bucket structure
    aws s3api put-object --bucket "$media_bucket" --key "images/" --content "" || warning "Failed to create images directory"
    aws s3api put-object --bucket "$media_bucket" --key "videos/" --content "" || warning "Failed to create videos directory"
    aws s3api put-object --bucket "$media_bucket" --key "documents/" --content "" || warning "Failed to create documents directory"
    
    # Logs bucket structure
    aws s3api put-object --bucket "$logs_bucket" --key "application/" --content "" || warning "Failed to create application logs directory"
    aws s3api put-object --bucket "$logs_bucket" --key "infrastructure/" --content "" || warning "Failed to create infrastructure logs directory"
    aws s3api put-object --bucket "$logs_bucket" --key "access/" --content "" || warning "Failed to create access logs directory"
    
    success "Directory structure created in all buckets"
}

# Validate Storage Setup
validate_storage_setup() {
    log "Validating storage setup..."
    
    local frontend_bucket=$(grep "FRONTEND_BUCKET=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local media_bucket=$(grep "MEDIA_BUCKET=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    local logs_bucket=$(grep "LOGS_BUCKET=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    
    # Check bucket existence
    local frontend_exists=$(aws s3 ls "s3://$frontend_bucket" 2>/dev/null && echo "exists" || echo "missing")
    local media_exists=$(aws s3 ls "s3://$media_bucket" 2>/dev/null && echo "exists" || echo "missing")
    local logs_exists=$(aws s3 ls "s3://$logs_bucket" 2>/dev/null && echo "exists" || echo "missing")
    
    if [ "$frontend_exists" = "exists" ]; then
        success "Frontend bucket is accessible: $frontend_bucket"
        
        # Get website endpoint
        local website_endpoint=$(aws s3api get-bucket-website --bucket "$frontend_bucket" --query 'IndexDocument.Suffix' --output text 2>/dev/null || echo "not configured")
        log "Frontend website endpoint: http://$frontend_bucket.s3-website-us-east-1.amazonaws.com"
    else
        error_exit "Frontend bucket not accessible: $frontend_bucket"
    fi
    
    if [ "$media_exists" = "exists" ]; then
        success "Media bucket is accessible: $media_bucket"
    else
        error_exit "Media bucket not accessible: $media_bucket"
    fi
    
    if [ "$logs_exists" = "exists" ]; then
        success "Logs bucket is accessible: $logs_bucket"
    else
        error_exit "Logs bucket not accessible: $logs_bucket"
    fi
    
    # Check bucket configurations
    log "Verifying bucket configurations..."
    
    # Check frontend bucket website configuration
    local website_config=$(aws s3api get-bucket-website --bucket "$frontend_bucket" 2>/dev/null && echo "configured" || echo "not configured")
    log "Frontend website configuration: $website_config"
    
    # Check encryption for private buckets
    local media_encryption=$(aws s3api get-bucket-encryption --bucket "$media_bucket" 2>/dev/null && echo "enabled" || echo "disabled")
    local logs_encryption=$(aws s3api get-bucket-encryption --bucket "$logs_bucket" 2>/dev/null && echo "enabled" || echo "disabled")
    log "Media bucket encryption: $media_encryption"
    log "Logs bucket encryption: $logs_encryption"
}

# Main execution
main() {
    log "Starting storage setup..."
    
    # Check if resource IDs file exists
    if [ ! -f "$RESOURCE_IDS_FILE" ]; then
        error_exit "Resource IDs file not found. Please run setup-vpc.sh first."
    fi
    
    setup_storage_resources
    validate_storage_setup
    
    success "Storage setup completed successfully!"
    
    # Display created resources
    echo "=========================================="
    echo "Storage Resources Created:"
    echo "=========================================="
    grep -E "(BUCKET)" "$RESOURCE_IDS_FILE"
    echo "=========================================="
    
    echo "Storage Endpoints:"
    local frontend_bucket=$(grep "FRONTEND_BUCKET=" "$RESOURCE_IDS_FILE" | cut -d'=' -f2)
    echo "Frontend Website: http://$frontend_bucket.s3-website-us-east-1.amazonaws.com"
    echo "=========================================="
}

# Execute main function
main "$@"
