# ufw-docker-protect

A production-grade utility that mimics **AWS Security Groups (SG)** for Docker containers directly on a single Linux host.

## Architecture

By default, when you publish a port in Docker (e.g., `docker run -p 8080:80`), Docker dynamically modifies iptables via the `FORWARD` and `PREROUTING` rules to inherently skip external firewall managers—like `ufw`. 

To solve this securely and efficiently, this tool manages the native `DOCKER-USER` chain to enforce an implicit **Default Deny** rule targeting the Docker bridges (`docker0` and `br+`). 

### How it behaves like an AWS Security Group
- **Default Drop**: If external traffic isn't expressly allowed, it's dropped. Period. 
- **Internal Freedom**: Containers can speak to other containers completely unhindered natively, exactly like resources within a common VPC or SG context.
- **Outbound Open**: Containers remain fully capable of reaching external endpoints.
- **Idempotent Allow Lists**: All exceptions must be explicitly registered via the `allow-port` command mapping ports to source IPs (or `0.0.0.0/0` catchall).

### UFW's Role (Visibility)
> **Note**: Do **NOT** rely on UFW to manage or block Docker ports. It structurally cannot do so while Docker's iptables engine runs.
We use `ufw` within this tool purely to maintain **visibility** and **logging** of what ports are officially allowed so that `ufw status` cleanly reflects reality. The physical **enforcement** behaves entirely within `iptables` and the `DOCKER-USER` managed chain.

## Setup Instructions

```bash
# Execute the install script
sudo bash install.sh

# Validate the daemon and configuration health
sudo ufw-docker-protect doctor
```

## Command Usage

```bash
# Allow generic internet access to Port 443 TCP
sudo ufw-docker-protect allow-port 443/tcp 0.0.0.0/0

# Allow specific IP access to an Admin portal on Port 22
sudo ufw-docker-protect allow-port 22/tcp 10.0.5.21/32

# Verify what rules are active globally
sudo ufw-docker-protect list-rules

# Revoke a previously issued security rule
sudo ufw-docker-protect revoke-port 443/tcp 0.0.0.0/0
```

## System Limitations & Safety
- **IPv6 Supported**: `ufw-docker-protect` seamlessly replicates logic into `ip6tables` automatically if detected. 
- **Daemon Independence**: This does not alter existing `docker-compose.yaml` or `docker run` definitions.
- **Docker Requirement**: The Docker engine must have `iptables: true` active (which is default). If you disable Docker's native iptables manipulation completely, this script is disabled safely.
