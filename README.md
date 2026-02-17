# OpenClaw Home

Bootstrap a complete OpenClaw environment on AWS EC2 in minutes. Includes zsh, Tailscale, Node.js, and AI coding tools.

## Quick Start

```bash
# 1. Create a new instance
./provision.sh

# 2. Connect (wait ~2 min after provisioning)
./connect.sh

# 3. When done - stop (keeps data) or terminate (deletes all)
./teardown.sh              # Stop
./teardown.sh --terminate  # Delete
```

## Requirements

### On Your Mac
- AWS CLI configured (`brew install awscli && aws configure`)
- SSH key will be created automatically

### EC2 Instance (created by provision.sh)
- **Default**: Amazon Linux 2023, t3.large (~$60/mo, 8 GB RAM)
- **Budget**: Set `INSTANCE_TYPE=t3.medium` (4 GB, may OOM under heavy use)
- **Free tier**: Set `INSTANCE_TYPE=t2.micro` (750 hrs/mo for 12 months)

## Configuration

Copy `.env.example` to `.env` and customize:

```bash
cp .env.example .env
# Edit .env with your settings
```

Key options:

| Variable | Default | Description |
|----------|---------|-------------|
| `INSTANCE_TYPE` | `t3.large` | EC2 instance type (8GB RAM needed for gateway + opencode) |
| `INSTANCE_NAME` | `openclaw-home` | Name tag for the instance |
| `VOLUME_SIZE` | `20` | Disk size in GB (minimum 20 recommended) |
| `OS` | `al2023` | Operating system (`al2023` or `ubuntu`) |
| `TAILSCALE_AUTHKEY` | - | Auto-connect Tailscale ([create key](https://login.tailscale.com/admin/settings/keys)) |
| `PRIVATE_MODE` | `auto` | SSH access mode (see below) |
| `ENABLE_BEDROCK` | `true` | Create IAM role for Bedrock access |

### Private Mode

Controls whether port 22 (SSH) is open to the internet:

| Value | Behavior |
|-------|----------|
| `auto` | Private if `TAILSCALE_AUTHKEY` is set, otherwise open (default) |
| `true` | Always private - SSH only via Tailscale |
| `false` | Always open port 22 |

When private mode is active, a separate security group (`openclaw-home-sg-private`) is created without inbound SSH rules. You must use Tailscale SSH to connect.

### AWS Permissions

The script needs two levels of AWS permissions:
- **EC2 operations**: PowerUserAccess is sufficient
- **IAM role creation**: Requires AdministratorAccess (or IAM permissions)

If your default profile lacks IAM permissions, set `AWS_ADMIN_PROFILE` to a profile with admin access:
```bash
AWS_ADMIN_PROFILE=my-admin-profile ./provision.sh
```

Or set `ENABLE_BEDROCK=false` to skip IAM setup and manually attach a role later.

### Disk Space Requirements

The full setup uses ~8GB:
| Component | Size |
|-----------|------|
| Homebrew + GCC + binutils | ~1.3GB |
| Bun | ~100MB |
| Node.js (nvm) | ~200MB |
| openclaw + skills | ~1GB |
| npm packages/cache | ~1-2GB |
| OS + base packages | ~3GB |

**Minimum: 20GB recommended** (default)

## What Gets Installed

| Component | Description |
|-----------|-------------|
| **Zsh** | Shell with Oh My Zsh, autosuggestions, syntax-highlighting |
| **Homebrew** | Package manager for Linux |
| **Node.js** | LTS version via nvm |
| **Bun** | Fast JavaScript runtime |
| **opencode** | AI coding assistant CLI |
| **openclaw** | AI assistant with Bedrock support (auto-configured) |
| **Tailscale** | Mesh VPN (auto-connects if TAILSCALE_AUTHKEY set) |
| **tmux** | Terminal multiplexer |
| **Build tools** | git, jq, etc. |

## Files

```
ec2-setup/
├── provision.sh      # Create EC2 instance (run from Mac)
├── connect.sh        # SSH to instance (run from Mac)
├── teardown.sh       # Stop/terminate (run from Mac)
├── setup.sh          # Manual/additional setup (optional, run ON EC2)
├── zshrc.template    # Shell config reference
├── .env              # Your config (gitignored)
└── .instance-info    # Created after provisioning (gitignored)
```

## Usage

### First Time Setup

```bash
cd ec2-setup
./provision.sh
# Wait ~2 minutes for instance to configure itself
./connect.sh
```

### Daily Workflow

```bash
./connect.sh          # Start working (auto-starts if stopped)
# ... do your work ...
./teardown.sh         # Stop when done (saves money, keeps data)
```

### OpenClaw Setup

OpenClaw is auto-installed and configured for Bedrock. On first connect:

```bash
# Start the gateway
openclaw gateway start

# Verify Bedrock models are available
openclaw models list
# Should show: amazon-bedrock/us.anthropic.claude-opus... with Auth: yes

# Run the onboarding wizard
openclaw onboard
```

### Tailscale Setup

If you set `TAILSCALE_AUTHKEY` in `.env`, Tailscale auto-connects on provisioning.

Otherwise, connect manually:
```bash
# On the EC2 instance:
sudo tailscale up

# Then connect via Tailscale IP (100.x.x.x)
# from any device on your tailnet
```

## Instance Types

| Type | vCPU | RAM | Cost | Notes |
|------|------|-----|------|-------|
| t2.micro | 1 | 1 GB | Free* | *750 hrs/mo for 12 months. Limited for AI tools |
| t3.micro | 2 | 1 GB | ~$8/mo | Better CPU, still limited RAM |
| t3.medium | 2 | 4 GB | ~$30/mo | Tight - may OOM with gateway + opencode |
| t3.large | 2 | 8 GB | ~$60/mo | **Recommended** for gateway + opencode sessions |

## Security

### How Access Works

| Method | When Available | Authentication |
|--------|----------------|----------------|
| Public IP + SSH key | Port 22 open in security group | Your SSH private key |
| Tailscale SSH | Tailscale running on both devices | Tailscale identity |

**Recommended:** Use Tailscale-only mode (no public SSH) for maximum security.

### Lock Down Instance (Tailscale Only)

Remove public SSH access so only Tailscale can connect:

```bash
# Close port 22 to the internet
aws ec2 revoke-security-group-ingress \
  --group-name "openclaw-home-sg" \
  --protocol tcp --port 22 --cidr 0.0.0.0/0 \
  --region us-east-1

# Verify (should return empty array)
aws ec2 describe-security-groups \
  --group-names "openclaw-home-sg" \
  --region us-east-1 \
  --query 'SecurityGroups[0].IpPermissions'
```

Now connect via: `ssh ec2-user@<tailscale-hostname>`

### Emergency Access (Re-open SSH)

If Tailscale breaks and you need to get back in:

```bash
# Option 1: Open to your current IP only (more secure)
MY_IP=$(curl -s ifconfig.me)
aws ec2 authorize-security-group-ingress \
  --group-name "openclaw-home-sg" \
  --protocol tcp --port 22 --cidr "$MY_IP/32" \
  --region us-east-1

# Option 2: Open to everyone (use temporarily, then close)
aws ec2 authorize-security-group-ingress \
  --group-name "openclaw-home-sg" \
  --protocol tcp --port 22 --cidr "0.0.0.0/0" \
  --region us-east-1
```

Then connect via: `ssh -i ~/.ssh/openclaw-home-key.pem ec2-user@<public-ip>`

### Recovery: Tailscale Down + Locked Out

If Tailscale is broken AND port 22 is closed:

1. Re-open port 22 (see above)
2. SSH via public IP
3. Fix Tailscale: `sudo systemctl restart tailscaled && sudo tailscale up`
4. Close port 22 again

## Monitoring

Provisioning installs the CloudWatch agent, which reports memory, swap, and disk metrics to the `OpenClawEC2` namespace every 60 seconds.

### What's included automatically
- **2 GB swap file** — prevents hard OOM kills
- **CloudWatch agent** — memory/swap/disk metrics
- **Gateway memory limits** — `MemoryHigh=5G`, `MemoryMax=6G` (systemd cgroup)

### Setting up alarms (recommended)
After provisioning, create CloudWatch alarms + SNS notifications:
```bash
# Create SNS topic and subscribe your email
aws sns create-topic --name dev-rig-alerts
aws sns subscribe --topic-arn arn:aws:sns:us-east-1:ACCOUNT_ID:dev-rig-alerts \
  --protocol email --notification-endpoint your@email.com
# Confirm the subscription via the email you receive

# Memory alarm (>85% for 5 min)
aws cloudwatch put-metric-alarm --alarm-name "dev-rig-memory-high" \
  --namespace OpenClawEC2 --metric-name mem_used_percent \
  --dimensions Name=InstanceId,Value=INSTANCE_ID \
  --statistic Average --period 300 --evaluation-periods 1 --threshold 85 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --alarm-actions arn:aws:sns:us-east-1:ACCOUNT_ID:dev-rig-alerts

# Auto-recovery on system failure
aws cloudwatch put-metric-alarm --alarm-name "dev-rig-status-check-failed" \
  --namespace AWS/EC2 --metric-name StatusCheckFailed_System \
  --dimensions Name=InstanceId,Value=INSTANCE_ID \
  --statistic Maximum --period 60 --evaluation-periods 2 --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --alarm-actions arn:aws:automate:us-east-1:ec2:recover \
    arn:aws:sns:us-east-1:ACCOUNT_ID:dev-rig-alerts
```

## Troubleshooting

### Can't connect after provisioning
Wait 2 minutes for the user-data script to complete. Check:
```bash
ssh -i ~/.ssh/openclaw-home-key.pem ec2-user@<IP> 'cat /var/log/user-data.log'
```

### Backspace not working
```bash
stty erase ^?
```

### Instance unresponsive (SSH times out, Tailscale ping fails)
Likely an OOM kill that cascaded. AWS health checks may still say "ok".
```bash
# Try a reboot first
aws ec2 reboot-instances --instance-ids INSTANCE_ID --region us-east-1

# If still unresponsive after 2 min, do a full stop/start
# (moves to new hardware, changes public IP, Tailscale IP stays the same)
aws ec2 stop-instances --instance-ids INSTANCE_ID --region us-east-1
aws ec2 wait instance-stopped --instance-ids INSTANCE_ID --region us-east-1
aws ec2 start-instances --instance-ids INSTANCE_ID --region us-east-1
```

Check for OOM kills after recovery:
```bash
ssh ec2-user@jarvis "sudo journalctl -b -1 -p err --no-pager | grep -i oom"
```

### Instance IP changed after restart
`./connect.sh` handles this automatically. It updates `.instance-info` when restarting a stopped instance.

### Permission denied (SSH)
```bash
chmod 400 ~/.ssh/openclaw-home-key.pem
```

## Cleanup

To fully clean up:
```bash
./teardown.sh --terminate
# This deletes the instance and security group
```

To also remove the key pair:
```bash
aws ec2 delete-key-pair --key-name openclaw-home-key
rm ~/.ssh/openclaw-home-key.pem
```
