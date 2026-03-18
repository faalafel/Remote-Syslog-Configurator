# Remote Syslog Forwarding Script

A bash script that configures rsyslog to forward logs to a remote syslog server.

## Supported Operating Systems

- RHEL 8.x / 9.x (including CentOS, Rocky, AlmaLinux, Oracle Linux)
- Ubuntu 22.04 / 24.04

## Features

- **Interactive configuration** - Prompts for remote server, port, and protocol
- **Protocol selection** - TCP (recommended) or UDP
- **Automatic backup** - Backs up existing configuration before changes
- **Configuration validation** - Validates rsyslog syntax before applying
- **Disk-assisted queuing** - Prevents log loss during network outages
- **SELinux support** - Automatically configures SELinux port policies on RHEL
- **Auto-rollback** - Restores backup if validation or restart fails
- **Test message** - Sends a test log entry to verify connectivity

## Prerequisites

- Root/sudo access
- rsyslog installed and running
- Network connectivity to the remote syslog server

## Usage

```bash
# Download and make executable
chmod +x remotesyslog.sh

# Run with sudo
sudo ./remotesyslog.sh
```

## Interactive Prompts

1. **Remote Server** - Hostname or IP address of the syslog server
2. **Port** - Remote port (default: 514)
3. **Protocol** - TCP (default) or UDP

## Configuration Output

The script creates `/etc/rsyslog.d/99-remote-forward.conf` with:

- RainerScript format for rsyslog 8.x+ compatibility
- Disk-assisted queue with 10,000 message buffer
- Automatic retry on connection failure
- Queue persistence on shutdown

## Example Configuration

```
*.* action(type="omfwd"
    target="syslog.example.com"
    port="514"
    protocol="tcp"
    action.resumeRetryCount="-1"
    queue.type="LinkedList"
    queue.size="10000"
    queue.filename="remote_fwd"
    queue.saveOnShutdown="on"
)
```

## Verification

After running the script, verify connectivity:

```bash
# For TCP
nc -zv <remote-host> <port>

# For UDP
nc -zuv <remote-host> <port>

# Check rsyslog status
systemctl status rsyslog

# View sent test message on remote server
tail -f /var/log/syslog      # Ubuntu
tail -f /var/log/messages    # RHEL
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Permission denied | Run with `sudo` |
| rsyslog not found | Install: `dnf install rsyslog` (RHEL) or `apt install rsyslog` (Ubuntu) |
| SELinux blocking | Script auto-configures; verify with `semanage port -l \| grep syslog` |
| Connection refused | Check firewall on remote server allows inbound on the configured port |

## Files

| Path | Description |
|------|-------------|
| `/etc/rsyslog.d/99-remote-forward.conf` | Generated forwarding configuration |
| `/var/spool/rsyslog/` | Disk queue storage directory |
| `*.bak.<timestamp>` | Backup of previous configuration |


