#!/bin/bash

# =============================================================================
# UPDATE FROM JFROG SCRIPT
# =============================================================================
# This script updates our artifactory-with-security.yaml with the latest
# JFrog Artifactory nginx configuration while preserving our DELETE protection
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
JFROG_NGINX_URL="https://raw.githubusercontent.com/jfrog/charts/master/stable/artifactory/files/nginx-artifactory-conf.yaml"
CURRENT_CONFIG="artifactory-with-security.yaml"
BACKUP_DIR="./backups"

# Functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check dependencies
check_dependencies() {
    log_info "Checking dependencies..."
    
    if ! command -v curl &> /dev/null; then
        log_error "curl is not installed. Please install curl first."
        exit 1
    fi
    
    log_success "Dependencies check complete"
}

# Download latest JFrog nginx config
download_latest_jfrog_config() {
    log_info "Downloading latest JFrog nginx configuration..."
    
    if curl -s -f "$JFROG_NGINX_URL" -o "jfrog-latest.conf"; then
        log_success "Latest JFrog config downloaded"
    else
        log_error "Failed to download from $JFROG_NGINX_URL"
        exit 1
    fi
    
    # Verify we got a valid config file
    if [[ ! -s "jfrog-latest.conf" ]]; then
        log_error "Downloaded config file is empty"
        exit 1
    fi
    
    # Check if it looks like a valid nginx config
    if ! grep -q "server" "jfrog-latest.conf"; then
        log_error "Downloaded file doesn't appear to be a valid nginx configuration"
        exit 1
    fi
    
    log_success "JFrog nginx configuration validated"
}

# Extract our DELETE protection blocks
extract_security_blocks() {
    log_info "Extracting our DELETE protection configuration..."
    
    # Our security maps and blocks
    cat > "security-additions.conf" << 'EOF'
    # ============================================================
    # DELETE PROTECTION CONFIGURATION
    # ============================================================
    # Map to identify IPs allowed for DELETE operations
    map $remote_addr $delete_allowed {
        default 0;  # By default, ALL IPs are BLOCKED for DELETE
        
        # AUTHORIZED IPs - CUSTOMIZE HERE
        172.16.1.99 1;    # Admin IP #1
        172.16.1.119 1;   # Admin IP #2 (current)
        172.16.1.100 1;   # Range coverage
        172.16.1.101 1;
        172.16.1.102 1;
        172.16.1.110 1;
        172.16.1.111 1;
        172.16.1.112 1;
        172.16.1.115 1;
        172.16.1.118 1;
        172.16.1.120 1;
        
        # Add other admin IPs here:
        # 192.168.1.100 1;  # Example admin IP
        # 10.0.0.50 1;      # Another admin IP
    }

    # Map to identify blocked DELETE requests
    map $request_method:$delete_allowed $delete_blocked {
        default 0;
        DELETE:0 1;
    }
EOF

    # API protection block
    cat > "api-protection.conf" << 'EOF'
        # =================================================================
        # DELETE PROTECTION - ARTIFACTORY API
        # =================================================================
        location ~ ^/artifactory/api/ {
          # DELETE verification
          set $delete_check 0;
          if ($request_method = DELETE) {
            set $delete_check 1;
          }
          if ($delete_allowed = 1) {
            set $delete_check 0;
          }
          if ($delete_check = 1) {
            add_header Content-Type "application/json" always;
            return 403 '{"error": "DELETE_OPERATION_BLOCKED", "status": 403, "message": "DELETE operations are restricted for security reasons.", "client_ip": "$remote_addr", "timestamp": "$time_iso8601"}';
          }
          
          # Security headers
          add_header X-Delete-Protection "enabled" always;
          
          # Standard proxy configuration
          proxy_read_timeout  900;
          proxy_pass_header   Server;
          proxy_cookie_path   ~*^/.* /;
          proxy_pass          http://artifactory;
          proxy_set_header    Connection "";
          proxy_set_header    X-JFrog-Override-Base-Url $http_x_forwarded_proto://$host;
          proxy_set_header    X-Forwarded-Port  $server_port;
          proxy_set_header    X-Forwarded-Proto $http_x_forwarded_proto;
          proxy_set_header    Host              $http_host;
          proxy_set_header    X-Forwarded-For   $proxy_add_x_forwarded_for;
        }

        # =================================================================
        # DELETE PROTECTION - MODERN UI API
        # =================================================================
        location ~ ^/ui/api/v1/ui/admin/repositories/.*/delete {
          # DELETE verification
          set $ui_api_delete_check 0;
          if ($request_method = DELETE) {
            set $ui_api_delete_check 1;
          }
          if ($delete_allowed = 1) {
            set $ui_api_delete_check 0;
          }
          if ($ui_api_delete_check = 1) {
            add_header Content-Type "application/json" always;
            return 403 '{"error": "UI_API_DELETE_BLOCKED", "status": 403, "message": "DELETE operations through modern UI API are restricted.", "client_ip": "$remote_addr", "timestamp": "$time_iso8601"}';
          }
          
          # Security headers
          add_header X-UI-API-Protection "enabled" always;
          
          # Proxy to UI API
          proxy_read_timeout  900;
          proxy_pass_header   Server;
          proxy_cookie_path   ~*^/.* /;
          proxy_pass          http://router;
          proxy_set_header    Connection "";
          proxy_set_header    X-JFrog-Override-Base-Url $http_x_forwarded_proto://$host;
          proxy_set_header    X-Forwarded-Port  $server_port;
          proxy_set_header    X-Forwarded-Proto $http_x_forwarded_proto;
          proxy_set_header    Host              $http_host;
          proxy_set_header    X-Forwarded-For   $proxy_add_x_forwarded_for;
        }
EOF
    
    log_success "Security blocks extracted"
}

# Create backup of current config
create_backup() {
    local timestamp=$(date +"%Y%m%d-%H%M%S")
    
    log_info "Creating backup of current configuration..."
    
    mkdir -p "$BACKUP_DIR"
    if [[ -f "$CURRENT_CONFIG" ]]; then
        cp "$CURRENT_CONFIG" "$BACKUP_DIR/artifactory-with-security-backup-$timestamp.yaml"
        log_info "Current config backed up to $BACKUP_DIR/artifactory-with-security-backup-$timestamp.yaml"
    fi
}

# Merge configurations
merge_configurations() {
    log_info "Merging JFrog config with our security additions..."
    
    # Create the merged nginx config
    cat > "merged-nginx.conf" << 'EOF'
    # Security-enhanced nginx configuration for Artifactory
    # Based on latest JFrog configuration with DELETE protection added
    
EOF
    
    # Add our security maps first
    cat "security-additions.conf" >> "merged-nginx.conf"
    echo "" >> "merged-nginx.conf"
    
    # Process the JFrog config and add our security blocks
    local in_server_block=false
    local server_content_added=false
    
    while IFS= read -r line; do
        echo "    $line" >> "merged-nginx.conf"
        
        # Detect server block start
        if [[ "$line" =~ ^[[:space:]]*server[[:space:]]*\{ ]]; then
            in_server_block=true
        fi
        
        # Add security logging after server block start
        if [[ "$in_server_block" == true && "$server_content_added" == false ]]; then
            if [[ "$line" =~ server_name || "$line" =~ listen ]]; then
                echo "    # Specialized logs for DELETE security" >> "merged-nginx.conf"
                echo "    access_log /var/opt/jfrog/nginx/logs/delete_blocked.log combined if=\$delete_blocked;" >> "merged-nginx.conf"
                echo "" >> "merged-nginx.conf"
                server_content_added=true
            fi
        fi
        
        # Add our security locations before the main location / block
        if [[ "$line" =~ ^[[:space:]]*location[[:space:]]+/[[:space:]]*\{ ]]; then
            cat "api-protection.conf" >> "merged-nginx.conf"
            echo "" >> "merged-nginx.conf"
        fi
        
    done < "jfrog-latest.conf"
    
    log_success "Configuration merged successfully"
}

# Generate new YAML file
generate_new_yaml() {
    log_info "Generating updated artifactory-with-security.yaml..."
    
    cat > "$CURRENT_CONFIG" << EOF
# =============================================================================
# ARTIFACTORY WITH DELETE PROTECTION - UPDATED VERSION
# =============================================================================
# Generated on: $(date)
# Based on latest JFrog Artifactory nginx configuration from:
# https://github.com/jfrog/charts/blob/master/stable/artifactory/files/nginx-artifactory-conf.yaml
# 
# This embeds the nginx config directly in Helm values
# So Helm templates are processed correctly

nginx:
  enabled: true
  artifactoryConf: |
$(cat "merged-nginx.conf")
EOF
    
    log_success "New configuration generated: $CURRENT_CONFIG"
}

# Cleanup temporary files
cleanup() {
    log_info "Cleaning up temporary files..."
    rm -f "jfrog-latest.conf" "security-additions.conf" "api-protection.conf" "merged-nginx.conf"
    log_success "Cleanup complete"
}

# Show diff with previous version
show_diff() {
    if [[ -f "$BACKUP_DIR"/*backup*.yaml ]]; then
        local latest_backup=$(ls -t "$BACKUP_DIR"/artifactory-with-security-backup-*.yaml | head -n1)
        log_info "Changes made:"
        echo "----------------------------------------"
        diff -u "$latest_backup" "$CURRENT_CONFIG" || true
        echo "----------------------------------------"
    fi
}

# Validate new configuration
validate_config() {
    log_info "Validating new configuration..."
    
    # Check if our security blocks are present
    if grep -q "DELETE_OPERATION_BLOCKED" "$CURRENT_CONFIG"; then
        log_success "DELETE protection blocks found"
    else
        log_warning "DELETE protection blocks not found - please review manually"
    fi
    
    # Check if it looks like valid YAML
    if grep -q "nginx:" "$CURRENT_CONFIG" && grep -q "artifactoryConf:" "$CURRENT_CONFIG"; then
        log_success "YAML structure looks valid"
    else
        log_error "YAML structure appears invalid"
        return 1
    fi
    
    log_success "Configuration validation complete"
}

# Show usage instructions
show_usage() {
    echo ""
    log_info "Update complete! Next steps:"
    echo "  1. Review the changes in $CURRENT_CONFIG"
    echo "  2. Update IP addresses if needed"
    echo "  3. Test with: helm upgrade --install --dry-run ..."
    echo "  4. Deploy when ready"
    echo ""
    log_info "To deploy the updated configuration:"
    echo "  helm upgrade --install artifactory jfrog/artifactory \\"
    echo "    -f $CURRENT_CONFIG \\"
    echo "    --namespace artifactory"
}

# Main execution
main() {
    echo "Updating Artifactory Security Config from Latest JFrog Chart"
    echo "==========================================================="
    
    check_dependencies
    create_backup
    download_latest_jfrog_config
    extract_security_blocks
    merge_configurations
    generate_new_yaml
    validate_config
    
    # Show results
    echo ""
    log_success "Configuration update complete!"
    show_diff
    show_usage
    
    cleanup
}

# Handle script interruption
trap cleanup EXIT

# Run main function
main "$@"
