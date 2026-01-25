#!/bin/bash
# provision.sh - Create an EC2 dev instance
#
# Run this from your Mac to spin up a new dev rig on AWS.
# The instance will be configured via user-data on first boot.
#
# Prerequisites: AWS CLI configured (run `aws configure` first)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env if exists (for TAILSCALE_AUTHKEY, etc.)
[ -f "$SCRIPT_DIR/.env" ] && source "$SCRIPT_DIR/.env"

# ============================================
# Configuration
# ============================================
INSTANCE_NAME="${INSTANCE_NAME:-dev-rig}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.medium}"  # t2.micro for free tier
VOLUME_SIZE="${VOLUME_SIZE:-20}"             # GB - Homebrew+bun+tools need ~8GB
REGION="${AWS_REGION:-us-east-1}"
KEY_NAME="${KEY_NAME:-dev-rig-key}"
SECURITY_GROUP_NAME="${SECURITY_GROUP_NAME:-dev-rig-sg}"
IAM_ROLE_NAME="${IAM_ROLE_NAME:-dev-rig-bedrock-role}"
ENABLE_BEDROCK="${ENABLE_BEDROCK:-true}"     # Attach IAM role for Bedrock access
OS="${OS:-al2023}"  # al2023, ubuntu
PRIVATE_MODE="${PRIVATE_MODE:-auto}"  # auto, true, false
# auto = private if TAILSCALE_AUTHKEY is set
# true = always private (require Tailscale for SSH)
# false = always open port 22

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# ============================================
# Pre-flight checks
# ============================================
log "Checking prerequisites..."

if ! command -v aws &> /dev/null; then
    err "AWS CLI not installed. Run: brew install awscli"
fi

if ! aws sts get-caller-identity &> /dev/null; then
    err "AWS credentials not configured. Run: aws configure"
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
log "AWS Account: $ACCOUNT_ID"
log "Region: $REGION"
log "Instance type: $INSTANCE_TYPE"

# ============================================
# Find AMI
# ============================================
log "Finding AMI for $OS..."

if [ "$OS" == "ubuntu" ]; then
    AMI_ID=$(aws ec2 describe-images \
        --region "$REGION" \
        --owners 099720109477 \
        --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
                  "Name=state,Values=available" \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
        --output text)
    SSH_USER="ubuntu"
else
    # Amazon Linux 2023
    AMI_ID=$(aws ec2 describe-images \
        --region "$REGION" \
        --owners amazon \
        --filters "Name=name,Values=al2023-ami-2023*-x86_64" \
                  "Name=state,Values=available" \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
        --output text)
    SSH_USER="ec2-user"
fi

if [ -z "$AMI_ID" ] || [ "$AMI_ID" == "None" ]; then
    err "Could not find AMI for $OS"
fi
success "AMI: $AMI_ID"

# ============================================
# Create or reuse key pair
# ============================================
KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"

if aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" &> /dev/null; then
    success "Using existing key pair: $KEY_NAME"
    if [ ! -f "$KEY_FILE" ]; then
        warn "Key file not found at $KEY_FILE - you may need to recreate the key pair"
    fi
else
    log "Creating key pair: $KEY_NAME"
    aws ec2 create-key-pair \
        --key-name "$KEY_NAME" \
        --region "$REGION" \
        --query 'KeyMaterial' \
        --output text > "$KEY_FILE"
    chmod 400 "$KEY_FILE"
    success "Key saved to: $KEY_FILE"
fi

# ============================================
# Determine if we should open SSH port
# ============================================
OPEN_SSH_PORT=true
if [ "$PRIVATE_MODE" == "true" ]; then
    OPEN_SSH_PORT=false
elif [ "$PRIVATE_MODE" == "auto" ] && [ -n "$TAILSCALE_AUTHKEY" ]; then
    OPEN_SSH_PORT=false
fi

if [ "$OPEN_SSH_PORT" == "false" ]; then
    warn "Private mode: SSH port 22 will NOT be opened. Use Tailscale to connect."
fi

# ============================================
# Create or reuse security group
# ============================================
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=is-default,Values=true" --query 'Vpcs[0].VpcId' --output text)

# Use different SG name for private mode to avoid conflicts
if [ "$OPEN_SSH_PORT" == "false" ]; then
    SECURITY_GROUP_NAME="${SECURITY_GROUP_NAME}-private"
fi

SG_ID=$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "None")

if [ "$SG_ID" == "None" ] || [ -z "$SG_ID" ]; then
    log "Creating security group: $SECURITY_GROUP_NAME"
    SG_ID=$(aws ec2 create-security-group \
        --group-name "$SECURITY_GROUP_NAME" \
        --description "Dev rig security group$([ "$OPEN_SSH_PORT" == "false" ] && echo " - private mode (Tailscale only)" || echo " - SSH access")" \
        --vpc-id "$VPC_ID" \
        --region "$REGION" \
        --query 'GroupId' \
        --output text)

    if [ "$OPEN_SSH_PORT" == "true" ]; then
        aws ec2 authorize-security-group-ingress \
            --group-id "$SG_ID" \
            --protocol tcp \
            --port 22 \
            --cidr 0.0.0.0/0 \
            --region "$REGION" > /dev/null
    fi
    success "Created security group: $SG_ID"
else
    success "Using existing security group: $SG_ID"
fi

# ============================================
# Create or reuse IAM role for Bedrock
# ============================================
INSTANCE_PROFILE_ARN=""
if [ "$ENABLE_BEDROCK" == "true" ]; then
    log "Setting up IAM role for Bedrock access..."

    # IAM operations need admin permissions - try to find a profile that works
    IAM_AWS="aws"
    if aws iam list-roles --max-items 1 &> /dev/null 2>&1; then
        : # Current profile works
    elif [ -n "$AWS_ADMIN_PROFILE" ] && AWS_PROFILE="$AWS_ADMIN_PROFILE" aws sts get-caller-identity &> /dev/null 2>&1; then
        IAM_AWS="env AWS_PROFILE=$AWS_ADMIN_PROFILE aws"
        log "Using $AWS_ADMIN_PROFILE profile for IAM operations"
    else
        warn "No IAM permissions available. Skipping Bedrock role setup."
        warn "Set AWS_ADMIN_PROFILE to a profile with IAM permissions, or manually attach a role later."
        ENABLE_BEDROCK="false"
    fi
fi

if [ "$ENABLE_BEDROCK" == "true" ]; then
    # Check if role exists
    if ! $IAM_AWS iam get-role --role-name "$IAM_ROLE_NAME" &> /dev/null; then
        log "Creating IAM role: $IAM_ROLE_NAME"

        # Create trust policy for EC2
        TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

        $IAM_AWS iam create-role \
            --role-name "$IAM_ROLE_NAME" \
            --assume-role-policy-document "$TRUST_POLICY" \
            --description "IAM role for EC2 dev rig with Bedrock access" > /dev/null

        # Attach Bedrock policy
        $IAM_AWS iam attach-role-policy \
            --role-name "$IAM_ROLE_NAME" \
            --policy-arn "arn:aws:iam::aws:policy/AmazonBedrockFullAccess"

        success "Created IAM role with Bedrock access"
    else
        success "Using existing IAM role: $IAM_ROLE_NAME"
    fi

    # Check if instance profile exists
    INSTANCE_PROFILE_NAME="$IAM_ROLE_NAME"
    if ! $IAM_AWS iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" &> /dev/null; then
        log "Creating instance profile: $INSTANCE_PROFILE_NAME"
        $IAM_AWS iam create-instance-profile \
            --instance-profile-name "$INSTANCE_PROFILE_NAME" > /dev/null

        $IAM_AWS iam add-role-to-instance-profile \
            --instance-profile-name "$INSTANCE_PROFILE_NAME" \
            --role-name "$IAM_ROLE_NAME"

        # Wait for instance profile to propagate
        log "Waiting for instance profile to propagate..."
        sleep 10
        success "Created instance profile"
    else
        success "Using existing instance profile: $INSTANCE_PROFILE_NAME"
    fi

    INSTANCE_PROFILE_ARN="arn:aws:iam::$ACCOUNT_ID:instance-profile/$INSTANCE_PROFILE_NAME"
fi

# ============================================
# User data script
# ============================================
if [ "$OS" == "ubuntu" ]; then
    USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
set -e
exec > /var/log/user-data.log 2>&1

apt-get update && apt-get upgrade -y
apt-get install -y git curl zsh tmux htop jq unzip build-essential

# Install Homebrew (as ubuntu user)
su - ubuntu -c 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'

# Install Node.js via nvm
su - ubuntu -c 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash'
su - ubuntu -c 'source ~/.nvm/nvm.sh && nvm install --lts'

# Install bun
su - ubuntu -c 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" && brew install oven-sh/bun/bun'

# Install AI tools
su - ubuntu -c 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" && source ~/.nvm/nvm.sh && npm install -g opencode-ai'
su - ubuntu -c 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" && source ~/.nvm/nvm.sh && npm install -g clawdbot'

# Oh My Zsh
su - ubuntu -c 'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'
su - ubuntu -c 'git clone https://github.com/zsh-users/zsh-autosuggestions ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions'
su - ubuntu -c 'git clone https://github.com/zsh-users/zsh-syntax-highlighting ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting'

# Configure zshrc
cat > /home/ubuntu/.zshrc << 'ZSHRC'
# Force compatible terminal type
export TERM=xterm-256color

export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting z)
source $ZSH/oh-my-zsh.sh

# Show hostname in prompt (so you know you're on EC2)
PROMPT="%m $PROMPT"

export EDITOR="nano"
export PATH="$HOME/.local/bin:$PATH"

# Homebrew
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

alias ez='$EDITOR ~/.zshrc'
alias sz='source ~/.zshrc'
alias ll='ls -la'
alias gs='git status'
alias gd='git diff'
alias gl='git log --oneline -10'
alias ta='tmux attach -t'
alias tl='tmux list-sessions'
alias tn='tmux new -s'
alias oc='opencode'
alias cb='clawdbot'

# Update all tools to latest
alias update-tools='brew update && brew upgrade && npm update -g opencode-ai clawdbot && echo "Tools updated!"'

# Clean up disk space
alias cleanup='brew cleanup -s && npm cache clean --force && rm -rf ~/.cache/* && echo "Cleaned!" && df -h /'

# AWS - EC2 instance role workaround for Bedrock
# Clawdbot checks for AWS_PROFILE env var to detect credentials
# Setting to 'default' signals credentials are available (via IMDS)
export AWS_PROFILE=default
export AWS_REGION=${AWS_REGION:-us-east-1}
ZSHRC
chown ubuntu:ubuntu /home/ubuntu/.zshrc

# Tailscale
curl -fsSL https://tailscale.com/install.sh | sh
__TAILSCALE_SETUP__

# Set zsh as default
chsh -s /bin/zsh ubuntu

# Configure clawdbot for Bedrock with US inference profile
su - ubuntu -c 'export AWS_PROFILE=default AWS_REGION=us-east-1 && source ~/.nvm/nvm.sh && clawdbot config set models.bedrockDiscovery.enabled true && clawdbot config set models.bedrockDiscovery.region us-east-1 && clawdbot config set models.providers.amazon-bedrock --json "{\"baseUrl\":\"https://bedrock-runtime.us-east-1.amazonaws.com\",\"api\":\"bedrock-converse-stream\",\"auth\":\"aws-sdk\",\"models\":[{\"id\":\"us.anthropic.claude-opus-4-5-20251101-v1:0\",\"name\":\"Claude Opus 4.5 (US)\",\"reasoning\":true,\"input\":[\"text\",\"image\"],\"contextWindow\":200000,\"maxTokens\":8192,\"cost\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0}}]}" && clawdbot models set amazon-bedrock/us.anthropic.claude-opus-4-5-20251101-v1:0' || true

# Signal completion
touch /home/ubuntu/.bootstrap-complete
USERDATA
)
else
    # Amazon Linux 2023
    USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
set -e
exec > /var/log/user-data.log 2>&1

dnf update -y
# Note: curl-minimal is pre-installed on AL2023, don't install curl (conflicts)
dnf install -y git zsh tmux htop jq unzip tar util-linux-user gcc make

# Install Homebrew (as ec2-user)
su - ec2-user -c 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'

# Install Node.js via nvm
su - ec2-user -c 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash'
su - ec2-user -c 'source ~/.nvm/nvm.sh && nvm install --lts'

# Install bun
su - ec2-user -c 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" && brew install oven-sh/bun/bun'

# Install AI tools
su - ec2-user -c 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" && source ~/.nvm/nvm.sh && npm install -g opencode-ai'
su - ec2-user -c 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" && source ~/.nvm/nvm.sh && npm install -g clawdbot'

# Oh My Zsh
su - ec2-user -c 'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'
su - ec2-user -c 'git clone https://github.com/zsh-users/zsh-autosuggestions ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions'
su - ec2-user -c 'git clone https://github.com/zsh-users/zsh-syntax-highlighting ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting'

# Configure zshrc
cat > /home/ec2-user/.zshrc << 'ZSHRC'
# Force compatible terminal type
export TERM=xterm-256color

export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting z)
source $ZSH/oh-my-zsh.sh

# Show hostname in prompt (so you know you're on EC2)
PROMPT="%m $PROMPT"

export EDITOR="nano"
export PATH="$HOME/.local/bin:$PATH"

# Homebrew
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

alias ez='$EDITOR ~/.zshrc'
alias sz='source ~/.zshrc'
alias ll='ls -la'
alias gs='git status'
alias gd='git diff'
alias gl='git log --oneline -10'
alias ta='tmux attach -t'
alias tl='tmux list-sessions'
alias tn='tmux new -s'
alias oc='opencode'
alias cb='clawdbot'

# Update all tools to latest
alias update-tools='brew update && brew upgrade && npm update -g opencode-ai clawdbot && echo "Tools updated!"'

# Clean up disk space
alias cleanup='brew cleanup -s && npm cache clean --force && rm -rf ~/.cache/* && echo "Cleaned!" && df -h /'

# AWS - EC2 instance role workaround for Bedrock
# Clawdbot checks for AWS_PROFILE env var to detect credentials
# Setting to 'default' signals credentials are available (via IMDS)
export AWS_PROFILE=default
export AWS_REGION=${AWS_REGION:-us-east-1}
ZSHRC
chown ec2-user:ec2-user /home/ec2-user/.zshrc

# Tailscale
curl -fsSL https://tailscale.com/install.sh | sh
__TAILSCALE_SETUP__

# Set zsh as default
chsh -s /bin/zsh ec2-user

# Configure clawdbot for Bedrock with US inference profile
su - ec2-user -c 'export AWS_PROFILE=default AWS_REGION=us-east-1 && source ~/.nvm/nvm.sh && clawdbot config set models.bedrockDiscovery.enabled true && clawdbot config set models.bedrockDiscovery.region us-east-1 && clawdbot config set models.providers.amazon-bedrock --json "{\"baseUrl\":\"https://bedrock-runtime.us-east-1.amazonaws.com\",\"api\":\"bedrock-converse-stream\",\"auth\":\"aws-sdk\",\"models\":[{\"id\":\"us.anthropic.claude-opus-4-5-20251101-v1:0\",\"name\":\"Claude Opus 4.5 (US)\",\"reasoning\":true,\"input\":[\"text\",\"image\"],\"contextWindow\":200000,\"maxTokens\":8192,\"cost\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0}}]}" && clawdbot models set amazon-bedrock/us.anthropic.claude-opus-4-5-20251101-v1:0' || true

# Signal completion
touch /home/ec2-user/.bootstrap-complete
USERDATA
)
fi

# Inject Tailscale auth key if provided
if [ -n "$TAILSCALE_AUTHKEY" ]; then
    USER_DATA="${USER_DATA/__TAILSCALE_SETUP__/tailscale up --authkey=\"$TAILSCALE_AUTHKEY\" --ssh}"
    log "Tailscale will auto-connect"
else
    USER_DATA="${USER_DATA/__TAILSCALE_SETUP__/# Run: sudo tailscale up}"
fi

# ============================================
# Launch instance
# ============================================
log "Launching EC2 instance..."

# Build run-instances command
RUN_ARGS=(
    --region "$REGION"
    --image-id "$AMI_ID"
    --instance-type "$INSTANCE_TYPE"
    --key-name "$KEY_NAME"
    --security-group-ids "$SG_ID"
    --user-data "$USER_DATA"
    --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":$VOLUME_SIZE,\"VolumeType\":\"gp3\"}}]"
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]"
)

# Add IAM instance profile if Bedrock is enabled
if [ -n "$INSTANCE_PROFILE_ARN" ]; then
    RUN_ARGS+=(--iam-instance-profile "Arn=$INSTANCE_PROFILE_ARN")
    log "Attaching IAM role for Bedrock access"
fi

INSTANCE_ID=$(aws ec2 run-instances \
    "${RUN_ARGS[@]}" \
    --query 'Instances[0].InstanceId' \
    --output text)

success "Instance launched: $INSTANCE_ID"

# ============================================
# Wait for instance
# ============================================
log "Waiting for instance to start..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"

PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

success "Instance running: $PUBLIC_IP"

# ============================================
# Save connection info
# ============================================
cat > "$SCRIPT_DIR/.instance-info" <<EOF
INSTANCE_ID=$INSTANCE_ID
PUBLIC_IP=$PUBLIC_IP
KEY_FILE=$KEY_FILE
REGION=$REGION
SSH_USER=$SSH_USER
EOF

echo ""
echo "=========================================="
echo "         Instance Ready!"
echo "=========================================="
echo ""
echo "Instance ID: $INSTANCE_ID"
echo "Public IP:   $PUBLIC_IP"
echo "SSH User:    $SSH_USER"
if [ "$OPEN_SSH_PORT" == "false" ]; then
    echo "Mode:        PRIVATE (Tailscale only)"
fi
echo ""
echo "Wait ~2 min for setup to complete, then connect:"
echo ""
if [ "$OPEN_SSH_PORT" == "false" ]; then
    echo "  ssh $SSH_USER@<tailscale-hostname>"
    echo ""
    echo "  (Port 22 is not open - use Tailscale SSH)"
else
    echo "  ./connect.sh"
    echo ""
    echo "Or manually:"
    echo "  ssh -i $KEY_FILE $SSH_USER@$PUBLIC_IP"
fi
echo ""
if [ -z "$TAILSCALE_AUTHKEY" ]; then
    echo "To set up Tailscale on the instance:"
    echo "  sudo tailscale up"
    echo ""
fi
