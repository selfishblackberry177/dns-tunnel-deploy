#!/bin/bash

# dnstt Client Setup Script
# Designed for copy-paste deployment on restricted networks
# Manages systemd services for dnstt-client instances

set -e

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[0;31m[ERROR]\033[0m This script must be run as root"
    exit 1
fi

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
DNSTT_CLIENT_BIN="/usr/local/bin/dnstt-client"
CONFIG_DIR="/etc/dnstt-client"
SYSTEMD_DIR="/etc/systemd/system"
SERVICE_PREFIX="dnstt-client-"

# Functions for colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_question() {
    echo -ne "${BLUE}[QUESTION]${NC} $1"
}

# Function to check if dnstt-client binary exists
check_dnstt_client() {
    if [[ ! -f "$DNSTT_CLIENT_BIN" ]]; then
        print_error "dnstt-client not found at $DNSTT_CLIENT_BIN"
        print_error "Please install dnstt-client manually before running this script."
        exit 1
    fi

    if [[ ! -x "$DNSTT_CLIENT_BIN" ]]; then
        print_error "dnstt-client at $DNSTT_CLIENT_BIN is not executable"
        exit 1
    fi

    print_status "Found dnstt-client at $DNSTT_CLIENT_BIN"
}

# Function to create config directory
create_config_dir() {
    if [[ ! -d "$CONFIG_DIR" ]]; then
        mkdir -p "$CONFIG_DIR"
        chmod 755 "$CONFIG_DIR"
        print_status "Created config directory: $CONFIG_DIR"
    fi
}

# Function to list existing dnstt-client services
list_services() {
    local services=()
    
    # Find all dnstt-client systemd services
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            services+=("$line")
        fi
    done < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null | grep "^${SERVICE_PREFIX}" | awk '{print $1}' | sed 's/\.service$//')
    
    echo "${services[@]}"
}

# Function to show service status
show_services_status() {
    local services
    services=($(list_services))
    
    if [[ ${#services[@]} -eq 0 ]]; then
        print_status "No existing dnstt-client services found."
        return 1
    fi
    
    echo ""
    print_status "Existing dnstt-client services:"
    echo ""
    printf "%-4s %-40s %-10s %-8s\n" "No." "Service Name" "Status" "Enabled"
    echo "--------------------------------------------------------------"
    
    local i=1
    for service in "${services[@]}"; do
        local status enabled
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            status="${GREEN}running${NC}"
        else
            status="${RED}stopped${NC}"
        fi
        
        if systemctl is-enabled --quiet "$service" 2>/dev/null; then
            enabled="${GREEN}yes${NC}"
        else
            enabled="${YELLOW}no${NC}"
        fi
        
        printf "%-4s %-40s " "$i)" "$service"
        echo -e "$status       $enabled"
        ((i++))
    done
    echo ""
    return 0
}

# Function to generate unique service name from domain and port
generate_service_name() {
    local domain="$1"
    local port="$2"
    
    # Sanitize domain: replace dots with underscores, remove other special chars
    local sanitized_domain
    sanitized_domain=$(echo "$domain" | sed 's/\./_/g' | sed 's/[^a-zA-Z0-9_-]//g')
    
    echo "${SERVICE_PREFIX}${sanitized_domain}_${port}"
}

# Function to get user input for new service
get_new_service_config() {
    echo ""
    print_status "Configure new dnstt-client instance"
    echo ""
    
    # DNS resolver
    print_question "Enter DNS resolver address (default: 127.0.0.53:53): "
    read -r DNS_RESOLVER
    if [[ -z "$DNS_RESOLVER" ]]; then
        DNS_RESOLVER="127.0.0.53:53"
    fi
    
    # Domain name (required)
    while true; do
        print_question "Enter domain name (e.g., d.example.com): "
        read -r DOMAIN_NAME
        
        if [[ -n "$DOMAIN_NAME" ]]; then
            break
        else
            print_error "Domain name is required"
        fi
    done
    
    # Public key (required)
    echo ""
    print_status "Enter the server's public key (paste the key content):"
    print_question "Public key: "
    read -r PUBLIC_KEY
    
    while [[ -z "$PUBLIC_KEY" ]]; do
        print_error "Public key is required"
        print_question "Public key: "
        read -r PUBLIC_KEY
    done
    
    # Listening port
    print_question "Enter local listening port (default: 7000): "
    read -r LISTEN_PORT
    if [[ -z "$LISTEN_PORT" ]]; then
        LISTEN_PORT="7000"
    fi
    
    # Extra arguments
    print_question "Enter extra arguments (optional, press Enter to skip): "
    read -r EXTRA_ARGS
    
    # Health check command (optional)
    echo ""
    print_status "Health check (optional): A command to periodically test if the tunnel is working."
    print_status "Examples:"
    echo "  SOCKS5: curl -x socks5h://127.0.0.1:7000 -s -o /dev/null https://www.google.com"
    echo "  SSH:    ssh -T -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes -i /path/to/key -p 7000 user@127.0.0.1 true"
    print_question "Enter health check command (press Enter to skip): "
    read -r HEALTH_CHECK_CMD
    
    # Health check interval (if health check is set)
    HEALTH_CHECK_INTERVAL="60"
    if [[ -n "$HEALTH_CHECK_CMD" ]]; then
        print_question "Enter health check interval in seconds (default: 60): "
        read -r interval_input
        if [[ -n "$interval_input" ]]; then
            HEALTH_CHECK_INTERVAL="$interval_input"
        fi
    fi
    
    # Generate service name
    SERVICE_NAME=$(generate_service_name "$DOMAIN_NAME" "$LISTEN_PORT")
    
    # Summary
    echo ""
    print_status "Configuration summary:"
    echo "  DNS Resolver:  $DNS_RESOLVER"
    echo "  Domain:        $DOMAIN_NAME"
    echo "  Listen Port:   $LISTEN_PORT"
    echo "  Service Name:  $SERVICE_NAME"
    if [[ -n "$EXTRA_ARGS" ]]; then
        echo "  Extra Args:    $EXTRA_ARGS"
    fi
    if [[ -n "$HEALTH_CHECK_CMD" ]]; then
        echo "  Health Check:  $HEALTH_CHECK_CMD"
        echo "  Check Interval: ${HEALTH_CHECK_INTERVAL}s"
    fi
    echo ""
    
    print_question "Create this service? (y/n): "
    read -r confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_warning "Service creation cancelled"
        return 1
    fi
    
    return 0
}

# Function to create a new dnstt-client service
create_service() {
    # Save public key to file
    local pubkey_file="${CONFIG_DIR}/${SERVICE_NAME}.pub"
    echo "$PUBLIC_KEY" > "$pubkey_file"
    chmod 644 "$pubkey_file"
    print_status "Public key saved to: $pubkey_file"
    
    # Create systemd service file
    local service_file="${SYSTEMD_DIR}/${SERVICE_NAME}.service"
    
    local extra_args_str=""
    if [[ -n "$EXTRA_ARGS" ]]; then
        extra_args_str=" $EXTRA_ARGS"
    fi
    
    cat > "$service_file" <<EOF
[Unit]
Description=dnstt DNS Tunnel Client ($DOMAIN_NAME -> 127.0.0.1:$LISTEN_PORT)
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=${DNSTT_CLIENT_BIN} -udp ${DNS_RESOLVER} -pubkey-file ${pubkey_file}${extra_args_str} ${DOMAIN_NAME} 127.0.0.1:${LISTEN_PORT}
Restart=always
RestartSec=5
KillMode=mixed
TimeoutStopSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    print_status "Systemd service created: $service_file"
    
    # Create health check if configured
    if [[ -n "$HEALTH_CHECK_CMD" ]]; then
        create_health_check
    fi
    
    # Reload systemd
    systemctl daemon-reload
    
    # Enable and start service
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"
    
    # Enable and start health check timer if configured
    if [[ -n "$HEALTH_CHECK_CMD" ]]; then
        systemctl enable "${SERVICE_NAME}-healthcheck.timer"
        systemctl start "${SERVICE_NAME}-healthcheck.timer"
        print_status "Health check timer enabled and started"
    fi
    
    print_status "Service $SERVICE_NAME enabled and started"
    
    # Show status
    echo ""
    systemctl status "$SERVICE_NAME" --no-pager -l
    
    echo ""
    print_status "Service management commands:"
    echo "  Status:  systemctl status $SERVICE_NAME"
    echo "  Stop:    systemctl stop $SERVICE_NAME"
    echo "  Start:   systemctl start $SERVICE_NAME"
    echo "  Logs:    journalctl -u $SERVICE_NAME -f"
    if [[ -n "$HEALTH_CHECK_CMD" ]]; then
        echo ""
        print_status "Health check commands:"
        echo "  Timer status:  systemctl status ${SERVICE_NAME}-healthcheck.timer"
        echo "  Manual check:  systemctl start ${SERVICE_NAME}-healthcheck.service"
        echo "  Check logs:    journalctl -u ${SERVICE_NAME}-healthcheck.service"
    fi
    echo ""
}

# Function to create health check script, service and timer
create_health_check() {
    local healthcheck_script="${CONFIG_DIR}/${SERVICE_NAME}-healthcheck.sh"
    local healthcheck_service="${SYSTEMD_DIR}/${SERVICE_NAME}-healthcheck.service"
    local healthcheck_timer="${SYSTEMD_DIR}/${SERVICE_NAME}-healthcheck.timer"
    
    # Create health check script with retry logic
    cat > "$healthcheck_script" <<'SCRIPT_EOF'
#!/bin/bash
# Health check script for SERVICE_NAME_PLACEHOLDER
# Generated by dnstt-client-deploy

SERVICE="SERVICE_NAME_PLACEHOLDER"
CHECK_CMD="HEALTH_CHECK_CMD_PLACEHOLDER"
MAX_RETRIES=3
RETRY_DELAY=5

echo "Starting health check for $SERVICE"
echo "Command: $CHECK_CMD"

# Wait for service to stabilize after startup
sleep 5

# Retry loop
for attempt in $(seq 1 $MAX_RETRIES); do
    echo "Attempt $attempt of $MAX_RETRIES..."
    
    if eval "$CHECK_CMD"; then
        echo "Health check passed for $SERVICE on attempt $attempt"
        exit 0
    else
        echo "Health check failed on attempt $attempt"
        if [[ $attempt -lt $MAX_RETRIES ]]; then
            echo "Waiting ${RETRY_DELAY}s before retry..."
            sleep $RETRY_DELAY
        fi
    fi
done

echo "All $MAX_RETRIES attempts failed for $SERVICE, restarting service..."
systemctl restart "$SERVICE"
exit 1
SCRIPT_EOF
    
    # Replace placeholders
    sed -i "s/SERVICE_NAME_PLACEHOLDER/$SERVICE_NAME/g" "$healthcheck_script"
    sed -i "s|HEALTH_CHECK_CMD_PLACEHOLDER|$HEALTH_CHECK_CMD|g" "$healthcheck_script"
    
    chmod 755 "$healthcheck_script"
    print_status "Health check script created: $healthcheck_script"
    
    # Create health check service
    cat > "$healthcheck_service" <<EOF
[Unit]
Description=Health check for $SERVICE_NAME
After=$SERVICE_NAME.service
Requires=$SERVICE_NAME.service

[Service]
Type=oneshot
User=root
Environment=HOME=/root
ExecStart=$healthcheck_script
# Ensure service waits for dnstt-client to be fully up
ExecStartPre=/bin/sleep 5
EOF
    
    print_status "Health check service created: $healthcheck_service"
    
    # Create health check timer - starts after service has been running for a while
    cat > "$healthcheck_timer" <<EOF
[Unit]
Description=Health check timer for $SERVICE_NAME
After=$SERVICE_NAME.service

[Timer]
OnBootSec=60
OnUnitActiveSec=${HEALTH_CHECK_INTERVAL}
Unit=${SERVICE_NAME}-healthcheck.service

[Install]
WantedBy=timers.target
EOF
    
    print_status "Health check timer created: $healthcheck_timer (interval: ${HEALTH_CHECK_INTERVAL}s)"
}

# Function to remove services
remove_services() {
    local services
    services=($(list_services))
    
    if [[ ${#services[@]} -eq 0 ]]; then
        print_status "No services to remove."
        return
    fi
    
    show_services_status
    
    print_question "Enter service number(s) to remove (comma-separated, e.g., 1,3) or 'all': "
    read -r selection
    
    if [[ -z "$selection" ]]; then
        print_warning "No selection made"
        return
    fi
    
    local to_remove=()
    
    if [[ "$selection" == "all" ]]; then
        to_remove=("${services[@]}")
    else
        IFS=',' read -ra selections <<< "$selection"
        for sel in "${selections[@]}"; do
            sel=$(echo "$sel" | tr -d ' ')
            if [[ "$sel" =~ ^[0-9]+$ ]] && [[ $sel -ge 1 ]] && [[ $sel -le ${#services[@]} ]]; then
                to_remove+=("${services[$((sel-1))]}")
            else
                print_warning "Invalid selection: $sel"
            fi
        done
    fi
    
    if [[ ${#to_remove[@]} -eq 0 ]]; then
        print_warning "No valid services selected"
        return
    fi
    
    echo ""
    print_warning "The following services will be removed:"
    for svc in "${to_remove[@]}"; do
        echo "  - $svc"
    done
    
    print_question "Confirm removal? (y/n): "
    read -r confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_warning "Removal cancelled"
        return
    fi
    
    for svc in "${to_remove[@]}"; do
        print_status "Removing $svc..."
        
        # Stop and disable service
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        
        # Stop and disable health check timer and service if they exist
        systemctl stop "${svc}-healthcheck.timer" 2>/dev/null || true
        systemctl disable "${svc}-healthcheck.timer" 2>/dev/null || true
        systemctl stop "${svc}-healthcheck.service" 2>/dev/null || true
        
        # Remove service file
        rm -f "${SYSTEMD_DIR}/${svc}.service"
        
        # Remove health check files
        rm -f "${SYSTEMD_DIR}/${svc}-healthcheck.service"
        rm -f "${SYSTEMD_DIR}/${svc}-healthcheck.timer"
        rm -f "${CONFIG_DIR}/${svc}-healthcheck.sh"
        
        # Remove public key file
        rm -f "${CONFIG_DIR}/${svc}.pub"
        
        print_status "Removed $svc"
    done
    
    # Reload systemd
    systemctl daemon-reload
    
    print_status "All selected services removed"
}

# Function to show main menu
show_menu() {
    echo ""
    print_status "dnstt Client Management"
    print_status "======================="
    echo ""
    echo "1) Create new dnstt-client instance"
    echo "2) Remove existing dnstt-client instance(s)"
    echo "3) Show all dnstt-client services status"
    echo "4) View logs for a service"
    echo "0) Exit"
    echo ""
    print_question "Please select an option (0-4): "
}

# Function to view logs
view_logs() {
    local services
    services=($(list_services))
    
    if [[ ${#services[@]} -eq 0 ]]; then
        print_status "No services found."
        return
    fi
    
    show_services_status
    
    print_question "Enter service number to view logs: "
    read -r selection
    
    if [[ "$selection" =~ ^[0-9]+$ ]] && [[ $selection -ge 1 ]] && [[ $selection -le ${#services[@]} ]]; then
        local svc="${services[$((selection-1))]}"
        print_status "Showing logs for $svc (Press Ctrl+C to exit)..."
        journalctl -u "$svc" -f
    else
        print_error "Invalid selection"
    fi
}

# Main function
main() {
    # Check for dnstt-client binary
    check_dnstt_client
    
    # Create config directory
    create_config_dir
    
    # Main menu loop
    while true; do
        show_menu
        read -r choice
        
        case $choice in
            1)
                if get_new_service_config; then
                    create_service
                fi
                ;;
            2)
                remove_services
                ;;
            3)
                show_services_status
                ;;
            4)
                view_logs
                ;;
            0)
                print_status "Goodbye!"
                exit 0
                ;;
            *)
                print_error "Invalid choice. Please enter 0-4."
                ;;
        esac
        
        if [[ "$choice" != "4" ]]; then
            echo ""
            print_question "Press Enter to continue..."
            read -r
        fi
    done
}

# Run main function
main "$@"
