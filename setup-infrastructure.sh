#!/bin/bash
# SmartTrip Infrastructure Setup Script
# This script provisions all AWS resources using AWS CLI commands
# Replaces Terraform-based infrastructure deployment

set -e  # Exit on any error

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/infrastructure-setup-$(date +%Y%m%d-%H%M%S).log"
CONFIG_FILE="$SCRIPT_DIR/config.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Error handling
error_exit() {
    echo -e "${RED}ERROR: $1${NC}" | tee -a "$LOG_FILE"
    exit 1
}

# Success message
success() {
    echo -e "${GREEN}SUCCESS: $1${NC}" | tee -a "$LOG_FILE"
}

# Warning message
warning() {
    echo -e "${YELLOW}WARNING: $1${NC}" | tee -a "$LOG_FILE"
}

# Check if AWS CLI is installed
check_dependencies() {
    log "Checking dependencies..."
    
    if ! command -v aws &> /dev/null; then
        error_exit "AWS CLI is not installed. Please install AWS CLI first."
    fi
    
    if ! command -v jq &> /dev/null; then
        error_exit "jq is not installed. Please install jq for JSON processing."
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        error_exit "AWS credentials not configured. Please run 'aws configure'."
    fi
    
    success "Dependencies check passed"
}

# Load configuration
load_config() {
    log "Loading configuration from $CONFIG_FILE..."
    
    if [ ! -f "$CONFIG_FILE" ]; then
        error_exit "Configuration file $CONFIG_FILE not found."
    fi
    
    # Validate JSON format
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        error_exit "Configuration file is not valid JSON."
    fi
    
    success "Configuration loaded successfully"
}

# Create main infrastructure setup script
setup_infrastructure() {
    log "Starting SmartTrip infrastructure setup..."
    
    # Execute setup scripts in order
    local scripts=(
        "setup-vpc.sh"
        "setup-security.sh" 
        "setup-databases.sh"
        "setup-compute.sh"
        "setup-storage.sh"
        "setup-networking.sh"
        "setup-monitoring.sh"
    )
    
    for script in "${scripts[@]}"; do
        if [ ! -f "$SCRIPT_DIR/$script" ]; then
            error_exit "Script $script not found in $SCRIPT_DIR"
        fi
        
        log "Executing $script..."
        chmod +x "$SCRIPT_DIR/$script"
        "$SCRIPT_DIR/$script" || error_exit "Script $script failed"
        success "Completed $script"
    done
    
    # Validate infrastructure
    log "Validating infrastructure..."
    "$SCRIPT_DIR/validate-infrastructure.sh" || error_exit "Infrastructure validation failed"
    
    success "Infrastructure setup completed successfully!"
    log "Log file: $LOG_FILE"
}

# Main execution
main() {
    echo "=========================================="
    echo "SmartTrip Infrastructure Setup"
    echo "=========================================="
    echo "Log file: $LOG_FILE"
    echo "=========================================="
    
    check_dependencies
    load_config
    setup_infrastructure
    
    echo "=========================================="
    echo "Setup completed successfully!"
    echo "=========================================="
    
    # Display resource information
    if [ -f "$SCRIPT_DIR/resource-ids.txt" ]; then
        echo "Resource IDs saved to: $SCRIPT_DIR/resource-ids.txt"
        cat "$SCRIPT_DIR/resource-ids.txt"
    fi
}

# Execute main function
main "$@"
