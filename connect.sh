#!/bin/bash
# connect.sh - Connect to your OpenClaw Home via SSH
#
# Tries Tailscale IP first (if available), falls back to public IP

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFO_FILE="$SCRIPT_DIR/.instance-info"

if [ ! -f "$INFO_FILE" ]; then
    echo "No instance info found. Run ./provision.sh first."
    exit 1
fi

source "$INFO_FILE"

# Check if instance is running
STATE=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo "unknown")

if [ "$STATE" == "stopped" ]; then
    echo "Instance is stopped. Starting it..."
    aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
    echo "Waiting for instance to start..."
    aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"

    # Update IP (may have changed)
    PUBLIC_IP=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$REGION" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)

    # Update info file
    sed -i '' "s/PUBLIC_IP=.*/PUBLIC_IP=$PUBLIC_IP/" "$INFO_FILE" 2>/dev/null || \
    sed -i "s/PUBLIC_IP=.*/PUBLIC_IP=$PUBLIC_IP/" "$INFO_FILE"

    echo "Instance started: $PUBLIC_IP"
    echo "Waiting for SSH to be ready..."
    sleep 10
fi

if [ "$STATE" == "terminated" ]; then
    echo "Instance has been terminated. Run ./provision.sh to create a new one."
    rm -f "$INFO_FILE"
    exit 1
fi

# Try to get Tailscale IP (look for any Linux host starting with "ip-")
TAILSCALE_IP=""
if command -v tailscale &> /dev/null; then
    TAILSCALE_IP=$(tailscale status --json 2>/dev/null | jq -r '.Peer[] | select(.HostName | startswith("ip-")) | .TailscaleIPs[0]' 2>/dev/null | head -1)
fi

# Connect (force xterm-256color for compatibility)
export TERM=xterm-256color

if [ -n "$TAILSCALE_IP" ] && [ "$TAILSCALE_IP" != "null" ]; then
    echo "Connecting via Tailscale: $TAILSCALE_IP"
    ssh "$SSH_USER@$TAILSCALE_IP"
else
    echo "Connecting via public IP: $PUBLIC_IP"
    ssh -i "$KEY_FILE" -o StrictHostKeyChecking=accept-new "$SSH_USER@$PUBLIC_IP"
fi
