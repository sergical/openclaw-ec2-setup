#!/bin/bash
# teardown.sh - Stop or terminate your dev rig
#
# Usage:
#   ./teardown.sh           # Stop instance (keeps data, can restart)
#   ./teardown.sh --terminate  # Delete instance permanently

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFO_FILE="$SCRIPT_DIR/.instance-info"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ ! -f "$INFO_FILE" ]; then
    echo "No instance info found. Nothing to tear down."
    exit 0
fi

source "$INFO_FILE"

# Check current state
STATE=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo "unknown")

echo "Instance: $INSTANCE_ID"
echo "Status:   $STATE"
echo ""

if [ "$STATE" == "terminated" ]; then
    echo "Instance already terminated."
    rm -f "$INFO_FILE"
    exit 0
fi

# Parse action
ACTION="stop"
if [ "$1" == "--terminate" ]; then
    ACTION="terminate"
fi

if [ "$ACTION" == "stop" ]; then
    if [ "$STATE" == "stopped" ]; then
        echo "Instance already stopped."
        exit 0
    fi

    echo "Stopping instance..."
    aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null

    echo -e "${GREEN}Instance stopped.${NC}"
    echo ""
    echo "Your data is preserved. To restart:"
    echo "  ./connect.sh"
    echo ""
    echo "To terminate permanently:"
    echo "  ./teardown.sh --terminate"
else
    echo -e "${YELLOW}WARNING: This will permanently delete your instance and all data!${NC}"
    read -p "Type 'yes' to confirm: " confirm

    if [ "$confirm" != "yes" ]; then
        echo "Cancelled."
        exit 0
    fi

    # Logout from Tailscale first (so device doesn't linger in your tailnet)
    echo "Logging out from Tailscale..."
    ssh -i "$KEY_FILE" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "$SSH_USER@$PUBLIC_IP" 'sudo tailscale logout' 2>/dev/null || true

    echo "Terminating instance..."
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null

    # Also try to delete security group (may fail if still in use)
    echo "Cleaning up security group (may take a moment)..."
    sleep 5
    aws ec2 delete-security-group --group-name "dev-rig-sg" --region "$REGION" 2>/dev/null || true
    aws ec2 delete-security-group --group-name "dev-rig-sg-private" --region "$REGION" 2>/dev/null || true

    rm -f "$INFO_FILE"

    echo -e "${GREEN}Instance terminated.${NC}"
    echo ""
    echo "To create a new instance:"
    echo "  ./provision.sh"
fi
