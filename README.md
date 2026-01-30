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
- **Default**: Amazon Linux 2023, t3.medium (~$30/mo)
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
| `INSTANCE_TYPE` | `t3.medium` | EC2 instance type (`t2.micro` for free tier) |
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
| t3.medium | 2 | 4 GB | ~$30/mo | **Recommended** for dev work |
| t3.large | 2 | 8 GB | ~$60/mo | More comfortable for heavy use |

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
