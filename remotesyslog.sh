#!/bin/bash
#
# Remote Syslog Forwarding Configuration Script
# Configures rsyslog to forward logs to a remote syslog server
# Supports: RHEL 8/9, Ubuntu 22.04/24.04
#


# Configuration variables
RSYSLOG_CONF_DIR="/etc/rsyslog.d"
REMOTE_CONF_FILE="${RSYSLOG_CONF_DIR}/99-remote-forward.conf"
BACKUP_SUFFIX=".bak.$(date +%Y%m%d%H%M%S)"

# Function to print messages
print_info() {
    echo "[INFO] $1"
}

print_error() {
    echo "[ERROR] $1" >&2
}

print_success() {
    echo "[SUCCESS] $1"
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root."
        echo ""
        echo "Please run with sudo or as root user:"
        echo "  sudo $0"
        echo ""
        exit 1
    fi
}

# Function to detect OS type and version
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_VERSION="${VERSION_ID}"
        OS_NAME="${NAME}"
    else
        print_error "Unable to detect operating system. /etc/os-release not found."
        exit 1
    fi

    # Validate supported OS
    case "${OS_ID}" in
        rhel|centos|rocky|almalinux|ol)
            OS_FAMILY="rhel"
            if [[ "${OS_VERSION%%.*}" -lt 8 ]]; then
                print_error "This script requires RHEL/CentOS 8 or later. Detected: ${OS_NAME} ${OS_VERSION}"
                exit 1
            fi
            ;;
        ubuntu)
            OS_FAMILY="ubuntu"
            if [[ "${OS_VERSION%%.*}" -lt 22 ]]; then
                print_error "This script requires Ubuntu 22.04 or later. Detected: ${OS_NAME} ${OS_VERSION}"
                exit 1
            fi
            ;;
        *)
            print_error "Unsupported operating system: ${OS_ID}"
            print_error "Supported: RHEL 8/9, Ubuntu 22.04/24.04"
            exit 1
            ;;
    esac

    print_info "Detected OS: ${OS_NAME} ${OS_VERSION}"
}

# Function to check if rsyslog is installed
check_rsyslog() {
    if ! command -v rsyslogd &> /dev/null; then
        print_error "rsyslog is not installed."
        echo ""
        if [[ "${OS_FAMILY}" == "rhel" ]]; then
            echo "Install rsyslog with: dnf install rsyslog"
        else
            echo "Install rsyslog with: apt install rsyslog"
        fi
        exit 1
    fi

    if ! systemctl is-active --quiet rsyslog; then
        print_info "rsyslog service is not running. Attempting to start..."
        systemctl start rsyslog
        if ! systemctl is-active --quiet rsyslog; then
            print_error "Failed to start rsyslog service."
            exit 1
        fi
    fi

    print_info "rsyslog is installed and running."
}

# Function to validate hostname or IP address
validate_host() {
    local host="$1"

    # Check if empty
    if [[ -z "${host}" ]]; then
        return 1
    fi

    # Validate IP address format (basic check)
    if [[ "${host}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        # Validate each octet
        IFS='.' read -ra OCTETS <<< "${host}"
        for octet in "${OCTETS[@]}"; do
            if [[ ${octet} -lt 0 || ${octet} -gt 255 ]]; then
                return 1
            fi
        done
        return 0
    fi

    # Validate hostname format (basic check)
    if [[ "${host}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 0
    fi

    return 1
}

# Function to validate port number
validate_port() {
    local port="$1"

    if [[ -z "${port}" ]]; then
        return 1
    fi

    if ! [[ "${port}" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    if [[ ${port} -lt 1 || ${port} -gt 65535 ]]; then
        return 1
    fi

    return 0
}

# Function to prompt for remote host
prompt_remote_host() {
    local input=""

    while true; do
        echo ""
        read -r -p "Enter the remote syslog server hostname or IP address: " input

        if validate_host "${input}"; then
            REMOTE_HOST="${input}"
            break
        else
            print_error "Invalid hostname or IP address. Please try again."
        fi
    done
}

# Function to prompt for port
prompt_port() {
    local input=""
    local default_port="514"

    while true; do
        echo ""
        read -r -p "Enter the remote syslog port [${default_port}]: " input

        # Use default if empty
        if [[ -z "${input}" ]]; then
            input="${default_port}"
        fi

        if validate_port "${input}"; then
            REMOTE_PORT="${input}"
            break
        else
            print_error "Invalid port number. Must be between 1 and 65535."
        fi
    done
}

# Function to prompt for protocol
prompt_protocol() {
    local input=""

    while true; do
        echo ""
        echo "Select transport protocol:"
        echo "  1) TCP (recommended - reliable delivery)"
        echo "  2) UDP (legacy - faster but unreliable)"
        read -r -p "Enter choice [1]: " input

        # Default to TCP
        if [[ -z "${input}" ]]; then
            input="1"
        fi

        case "${input}" in
            1)
                PROTOCOL="tcp"
                PROTOCOL_PREFIX="@@"
                break
                ;;
            2)
                PROTOCOL="udp"
                PROTOCOL_PREFIX="@"
                break
                ;;
            *)
                print_error "Invalid selection. Please choose 1 or 2."
                ;;
        esac
    done
}

# Function to backup existing configuration
backup_config() {
    if [[ -f "${REMOTE_CONF_FILE}" ]]; then
        print_info "Backing up existing configuration..."
        cp "${REMOTE_CONF_FILE}" "${REMOTE_CONF_FILE}${BACKUP_SUFFIX}"
        print_info "Backup saved to: ${REMOTE_CONF_FILE}${BACKUP_SUFFIX}"
    fi
}

# Function to create rsyslog forwarding configuration
create_config() {
    print_info "Creating rsyslog forwarding configuration..."

    # Create the configuration directory if it does not exist
    if [[ ! -d "${RSYSLOG_CONF_DIR}" ]]; then
        mkdir -p "${RSYSLOG_CONF_DIR}"
    fi

    # Ensure spool directory exists for disk-assisted queuing
    local spool_dir="/var/spool/rsyslog"
    if [[ ! -d "${spool_dir}" ]]; then
        mkdir -p "${spool_dir}"
        chown root:root "${spool_dir}"
        chmod 700 "${spool_dir}"
    fi

    # Create the configuration file using RainerScript format for better compatibility
    # This format works on rsyslog 8.x+ (RHEL 8/9, Ubuntu 22/24)
    cat > "${REMOTE_CONF_FILE}" << EOF
# Remote Syslog Forwarding Configuration
# Generated by remotesyslog.sh on $(date)
# Server: ${REMOTE_HOST}:${REMOTE_PORT} (${PROTOCOL^^})

# Set working directory for disk-assisted queuing
\$WorkDirectory /var/spool/rsyslog

# Forward all logs to remote syslog server
*.* action(type="omfwd"
    target="${REMOTE_HOST}"
    port="${REMOTE_PORT}"
    protocol="${PROTOCOL}"
    action.resumeRetryCount="-1"
    queue.type="LinkedList"
    queue.size="10000"
    queue.filename="remote_fwd"
    queue.saveOnShutdown="on"
)
EOF

    # Set proper permissions
    chmod 644 "${REMOTE_CONF_FILE}"

    print_info "Configuration written to: ${REMOTE_CONF_FILE}"
}

# Function to validate rsyslog configuration
validate_config() {
    print_info "Validating rsyslog configuration..."

    # Check configuration syntax
    # rsyslogd -N1 validates config and returns 0 on success
    local validation_output
    validation_output=$(rsyslogd -N1 2>&1)
    local validation_result=$?

    if [[ ${validation_result} -eq 0 ]]; then
        print_info "Configuration syntax is valid."
        return 0
    else
        print_error "Configuration validation failed:"
        echo "${validation_output}"
        return 1
    fi
}

# Function to restart rsyslog service
restart_rsyslog() {
    print_info "Restarting rsyslog service..."

    if systemctl restart rsyslog; then
        sleep 2
        if systemctl is-active --quiet rsyslog; then
            print_info "rsyslog service restarted successfully."
            return 0
        fi
    fi

    print_error "Failed to restart rsyslog service."
    return 1
}

# Function to test the configuration
test_config() {
    print_info "Testing syslog forwarding..."

    # Send a test message
    local test_message="Test message from $(hostname) - Remote syslog configuration validation"

    logger -p local0.info "${test_message}"

    print_info "Test message sent via logger."
    echo ""
    echo "To verify the message was received, check the remote syslog server logs"
    echo "or use the following command on the remote server:"
    echo "  tail -f /var/log/syslog    (Ubuntu)"
    echo "  tail -f /var/log/messages  (RHEL)"
    echo ""
}

# Function to display configuration summary
display_summary() {
    echo ""
    echo "=========================================="
    echo "  Remote Syslog Configuration Summary"
    echo "=========================================="
    echo ""
    echo "  Remote Server: ${REMOTE_HOST}"
    echo "  Port:          ${REMOTE_PORT}"
    echo "  Protocol:      ${PROTOCOL^^}"
    echo "  Config File:   ${REMOTE_CONF_FILE}"
    echo ""
    echo "=========================================="
    echo ""
}

# Function to configure SELinux if needed (RHEL)
configure_selinux() {
    if [[ "${OS_FAMILY}" != "rhel" ]]; then
        return 0
    fi

    if ! command -v getenforce &> /dev/null; then
        return 0
    fi

    local selinux_status
    selinux_status=$(getenforce 2>/dev/null || echo "Disabled")

    if [[ "${selinux_status}" == "Enforcing" ]]; then
        print_info "SELinux is enforcing. Configuring syslog port policy..."

        # Check if semanage is available
        if command -v semanage &> /dev/null; then
            # Allow rsyslog to connect to the remote port
            if semanage port -l | grep -q "syslogd_port_t.*${REMOTE_PORT}"; then
                print_info "SELinux port policy already configured for port ${REMOTE_PORT}."
            else
                print_info "Adding SELinux port policy for port ${REMOTE_PORT}..."
                semanage port -a -t syslogd_port_t -p "${PROTOCOL}" "${REMOTE_PORT}" 2>/dev/null || \
                semanage port -m -t syslogd_port_t -p "${PROTOCOL}" "${REMOTE_PORT}" 2>/dev/null || true
            fi
        else
            print_info "semanage not found. Install policycoreutils-python-utils if SELinux issues occur."
        fi
    fi
}

# Function to configure firewall if needed
check_firewall() {
    echo ""
    print_info "Network connectivity reminder:"
    echo ""
    echo "  This server will send logs OUTBOUND to ${REMOTE_HOST}:${REMOTE_PORT} (${PROTOCOL^^})."
    echo "  Outbound traffic is typically allowed by default."
    echo ""
    echo "  To test connectivity to the remote server:"
    if [[ "${PROTOCOL}" == "tcp" ]]; then
        echo "    nc -zv ${REMOTE_HOST} ${REMOTE_PORT}"
    else
        echo "    nc -zuv ${REMOTE_HOST} ${REMOTE_PORT}"
    fi
    echo ""
    echo "  On the REMOTE syslog server, ensure:"
    echo "    - Port ${REMOTE_PORT}/${PROTOCOL^^} is open for inbound connections"
    echo "    - rsyslog is configured to accept remote logs"
    echo ""
}

# Main function
main() {
    echo ""
    echo "=========================================="
    echo "  Remote Syslog Forwarding Configuration"
    echo "=========================================="
    echo ""

    # Check for root privileges
    check_root

    # Detect operating system
    detect_os

    # Check rsyslog installation
    check_rsyslog

    # Prompt for configuration
    prompt_remote_host
    prompt_port
    prompt_protocol

    # Display summary and confirm
    echo ""
    echo "Configuration to be applied:"
    echo "  Remote Server: ${REMOTE_HOST}"
    echo "  Port:          ${REMOTE_PORT}"
    echo "  Protocol:      ${PROTOCOL^^}"
    echo ""
    read -r -p "Proceed with configuration? [Y/n]: " confirm

    if [[ "${confirm,,}" == "n" ]]; then
        print_info "Configuration cancelled."
        exit 0
    fi

    # Backup existing configuration
    backup_config

    # Create new configuration
    create_config

    # Configure SELinux if applicable
    configure_selinux

    # Validate configuration
    if ! validate_config; then
        print_error "Configuration validation failed. Restoring backup if available."
        if [[ -f "${REMOTE_CONF_FILE}${BACKUP_SUFFIX}" ]]; then
            mv "${REMOTE_CONF_FILE}${BACKUP_SUFFIX}" "${REMOTE_CONF_FILE}"
        else
            rm -f "${REMOTE_CONF_FILE}"
        fi
        exit 1
    fi

    # Restart rsyslog
    if ! restart_rsyslog; then
        print_error "Failed to restart rsyslog. Restoring backup if available."
        if [[ -f "${REMOTE_CONF_FILE}${BACKUP_SUFFIX}" ]]; then
            mv "${REMOTE_CONF_FILE}${BACKUP_SUFFIX}" "${REMOTE_CONF_FILE}"
            systemctl restart rsyslog
        fi
        exit 1
    fi

    # Display configuration summary
    display_summary

    # Check firewall
    check_firewall

    # Send test message
    test_config

    # Success message
    print_success "Remote syslog forwarding has been configured successfully."
    print_success "All logs will be forwarded to ${REMOTE_HOST}:${REMOTE_PORT} via ${PROTOCOL^^}."
    echo ""

    exit 0
}

# Run main function
main
