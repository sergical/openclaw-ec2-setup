#!/bin/bash
set -e

# =============================================================================
# EC2 Dev Rig Setup Script
# =============================================================================
# Idempotent setup script for bootstrapping a dev environment on EC2.
# Works on Amazon Linux 2023, Amazon Linux 2, and Ubuntu.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Prompt helper - returns 0 for yes, 1 for no
prompt_yn() {
    local prompt="$1"
    local default="${2:-n}"
    local response

    if [[ "$default" == "y" ]]; then
        read -p "$prompt [Y/n]: " response
        response=${response:-y}
    else
        read -p "$prompt [y/N]: " response
        response=${response:-n}
    fi

    [[ "$response" =~ ^[Yy] ]]
}

# =============================================================================
# OS Detection
# =============================================================================

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
    else
        log_error "Cannot detect OS. /etc/os-release not found."
        exit 1
    fi

    case "$OS_ID" in
        amzn)
            if [[ "$OS_VERSION" == "2023" ]]; then
                OS_TYPE="al2023"
                PKG_MANAGER="dnf"
            else
                OS_TYPE="al2"
                PKG_MANAGER="yum"
            fi
            ;;
        ubuntu|debian)
            OS_TYPE="ubuntu"
            PKG_MANAGER="apt"
            ;;
        *)
            log_warn "Unknown OS: $OS_ID. Attempting to continue with apt..."
            OS_TYPE="ubuntu"
            PKG_MANAGER="apt"
            ;;
    esac

    log_info "Detected OS: $OS_ID $OS_VERSION (using $PKG_MANAGER)"
}

# =============================================================================
# Package Installation
# =============================================================================

install_packages() {
    local packages="$@"

    case "$PKG_MANAGER" in
        dnf)
            sudo dnf install -y $packages
            ;;
        yum)
            sudo yum install -y $packages
            ;;
        apt)
            sudo apt-get update
            sudo apt-get install -y $packages
            ;;
    esac
}

# =============================================================================
# Base Setup
# =============================================================================

install_base_packages() {
    log_info "Installing base packages..."

    case "$PKG_MANAGER" in
        dnf|yum)
            install_packages zsh git jq curl unzip tar util-linux-user
            ;;
        apt)
            install_packages zsh git jq curl unzip
            ;;
    esac

    log_success "Base packages installed"
}

# =============================================================================
# Oh My Zsh
# =============================================================================

install_oh_my_zsh() {
    if [[ -d "$HOME/.oh-my-zsh" ]]; then
        log_success "Oh My Zsh already installed"
        return
    fi

    log_info "Installing Oh My Zsh..."

    # Unattended install - won't change shell or start zsh
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

    log_success "Oh My Zsh installed"
}

# =============================================================================
# Zsh Plugins
# =============================================================================

install_zsh_plugins() {
    local plugins_dir="$HOME/.oh-my-zsh/custom/plugins"

    # zsh-autosuggestions
    if [[ ! -d "$plugins_dir/zsh-autosuggestions" ]]; then
        log_info "Installing zsh-autosuggestions..."
        git clone https://github.com/zsh-users/zsh-autosuggestions "$plugins_dir/zsh-autosuggestions"
    else
        log_success "zsh-autosuggestions already installed"
    fi

    # zsh-syntax-highlighting
    if [[ ! -d "$plugins_dir/zsh-syntax-highlighting" ]]; then
        log_info "Installing zsh-syntax-highlighting..."
        git clone https://github.com/zsh-users/zsh-syntax-highlighting "$plugins_dir/zsh-syntax-highlighting"
    else
        log_success "zsh-syntax-highlighting already installed"
    fi

    log_success "Zsh plugins installed"
}

# =============================================================================
# Tailscale
# =============================================================================

install_tailscale() {
    if command -v tailscale &>/dev/null; then
        log_success "Tailscale already installed"
        return
    fi

    log_info "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh

    log_success "Tailscale installed"
    log_info "Run 'sudo tailscale up' to authenticate"
}

# =============================================================================
# Node.js (via nvm)
# =============================================================================

install_nvm_node() {
    export NVM_DIR="$HOME/.nvm"

    if [[ ! -d "$NVM_DIR" ]]; then
        log_info "Installing nvm..."
        curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    else
        log_success "nvm already installed"
    fi

    # Load nvm
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

    # Install Node LTS if not present
    if ! command -v node &>/dev/null; then
        log_info "Installing Node.js LTS..."
        nvm install --lts
        nvm use --lts
        nvm alias default lts/*
    else
        log_success "Node.js already installed: $(node --version)"
    fi

    log_success "Node.js setup complete"
}

# =============================================================================
# opencode
# =============================================================================

install_opencode() {
    # Load nvm if available
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

    if command -v opencode &>/dev/null; then
        log_success "opencode already installed"
        return
    fi

    if ! command -v npm &>/dev/null; then
        log_error "npm not found. Please install Node.js first."
        return 1
    fi

    log_info "Installing opencode..."
    npm install -g @anthropic-ai/opencode

    log_success "opencode installed"
}

# =============================================================================
# clawdbot
# =============================================================================

install_clawdbot() {
    # Load nvm if available
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

    if command -v clawdbot &>/dev/null; then
        log_success "clawdbot already installed"
        return
    fi

    if ! command -v npm &>/dev/null; then
        log_error "npm not found. Please install Node.js first."
        return 1
    fi

    log_info "Installing clawdbot..."
    npm install -g clawdbot

    log_success "clawdbot installed"
}

# =============================================================================
# Bedrock Configuration
# =============================================================================

configure_bedrock() {
    log_info "Configuring Bedrock access..."

    # Create AWS credentials directory if needed
    mkdir -p "$HOME/.aws"

    # Create default profile if it doesn't exist
    if [[ ! -f "$HOME/.aws/config" ]]; then
        cat > "$HOME/.aws/config" << 'EOF'
[default]
region = us-east-1
EOF
        log_success "Created ~/.aws/config"
    else
        log_success "~/.aws/config already exists"
    fi

    # Create clawdbot config for Bedrock
    local clawdbot_config_dir="$HOME/.config/clawdbot"
    mkdir -p "$clawdbot_config_dir"

    if [[ ! -f "$clawdbot_config_dir/config.json" ]]; then
        cat > "$clawdbot_config_dir/config.json" << 'EOF'
{
  "provider": "bedrock",
  "model": "anthropic.claude-sonnet-4-20250514-v1:0",
  "region": "us-east-1"
}
EOF
        log_success "Created clawdbot Bedrock config"
    else
        log_success "clawdbot config already exists"
    fi

    log_success "Bedrock configuration complete"
    log_info "Ensure your EC2 instance has an IAM role with AmazonBedrockFullAccess"
}

# =============================================================================
# Zshrc Setup
# =============================================================================

setup_zshrc() {
    local template_file="$SCRIPT_DIR/zshrc.template"
    local zshrc_file="$HOME/.zshrc"

    # Check if template exists
    if [[ ! -f "$template_file" ]]; then
        log_warn "zshrc.template not found at $template_file"
        log_info "Creating default zshrc..."

        # Create inline if template missing (for curl | bash installs)
        cat > "$zshrc_file" << 'ZSHRC'
# Oh My Zsh
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting z)
source $ZSH/oh-my-zsh.sh

# Editor
export EDITOR="nano"

# Aliases - Shell
alias ez='$EDITOR ~/.zshrc'
alias sz='source ~/.zshrc'

# Aliases - Git
alias gs='git status'
alias gfp='git fetch origin && git pull origin'
alias gac='git add . && git commit -m'

# Aliases - Dev tools (if installed)
command -v pnpm &>/dev/null && alias pnd='pnpm run dev'
command -v opencode &>/dev/null && alias oc='opencode'
command -v clawdbot &>/dev/null && alias cb='clawdbot'

# NVM
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# AWS - EC2 instance role workaround for Bedrock
if [[ -f /sys/hypervisor/uuid ]] && grep -qi ec2 /sys/hypervisor/uuid 2>/dev/null; then
  export AWS_PROFILE=default
  export AWS_REGION=${AWS_REGION:-us-east-1}
fi

# Path
export PATH="$HOME/.local/bin:$PATH"
ZSHRC
    else
        # Backup existing zshrc if it exists and is different
        if [[ -f "$zshrc_file" ]]; then
            if ! diff -q "$template_file" "$zshrc_file" &>/dev/null; then
                local backup="$zshrc_file.backup.$(date +%Y%m%d%H%M%S)"
                cp "$zshrc_file" "$backup"
                log_info "Backed up existing .zshrc to $backup"
            fi
        fi

        cp "$template_file" "$zshrc_file"
    fi

    log_success "Zshrc configured"
}

# =============================================================================
# Set Default Shell
# =============================================================================

set_default_shell() {
    local zsh_path
    zsh_path=$(which zsh)

    if [[ "$SHELL" == "$zsh_path" ]]; then
        log_success "Zsh is already the default shell"
        return
    fi

    log_info "Setting zsh as default shell..."

    # Add zsh to /etc/shells if not present
    if ! grep -q "$zsh_path" /etc/shells; then
        echo "$zsh_path" | sudo tee -a /etc/shells > /dev/null
    fi

    # Change shell
    sudo chsh -s "$zsh_path" "$USER"

    log_success "Default shell changed to zsh"
    log_info "Log out and back in for the change to take effect"
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo "=========================================="
    echo "       EC2 Dev Rig Setup Script"
    echo "=========================================="
    echo ""

    # Detect OS first
    detect_os

    # Required components
    install_base_packages
    install_oh_my_zsh
    install_zsh_plugins

    echo ""

    # Optional: Tailscale
    if prompt_yn "Install Tailscale (secure mesh VPN)?"; then
        install_tailscale
    fi

    # Optional: Node.js
    local install_node=false
    if prompt_yn "Install Node.js via nvm?"; then
        install_node=true
        install_nvm_node
    fi

    # Optional: opencode (requires Node)
    if [[ "$install_node" == true ]] || command -v npm &>/dev/null; then
        if prompt_yn "Install opencode (AI coding CLI)?"; then
            install_opencode
        fi

        if prompt_yn "Install clawdbot (AI assistant)?"; then
            install_clawdbot

            if prompt_yn "Configure clawdbot for AWS Bedrock?"; then
                configure_bedrock
            fi
        fi
    fi

    # Setup zshrc
    setup_zshrc

    # Set default shell
    set_default_shell

    echo ""
    echo "=========================================="
    echo "           Setup Complete!"
    echo "=========================================="
    echo ""
    log_info "Next steps:"
    echo "  1. Log out and back in (or run: exec zsh)"
    echo "  2. If you installed Tailscale: sudo tailscale up"
    echo "  3. Verify: zsh --version, node --version"
    echo ""
}

main "$@"
