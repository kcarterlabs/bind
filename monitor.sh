#!/bin/bash
# Health check script for BIND DNS container
# This script checks if the container is running and healthy
# If not, it redeploys using deploy.sh

CONTAINER_NAME="bind-flask"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/bind-monitor.log"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Check if container exists and is running
if docker ps --filter "name=$CONTAINER_NAME" --filter "status=running" | grep -q "$CONTAINER_NAME"; then
    # Container is running, check if it's healthy
    # Try a simple DNS query to verify it's responding
    if dig @localhost kcarterlabs.tech +short > /dev/null 2>&1; then
        # Container is healthy, no action needed
        exit 0
    else
        log_message "Container $CONTAINER_NAME is running but not responding to DNS queries. Restarting..."
        docker restart "$CONTAINER_NAME"
        sleep 5
        
        # Check again after restart
        if dig @localhost kcarterlabs.tech +short > /dev/null 2>&1; then
            log_message "Container $CONTAINER_NAME successfully restarted and healthy."
        else
            log_message "Container $CONTAINER_NAME failed health check after restart. Running full deployment..."
            cd "$SCRIPT_DIR" && bash deploy.sh >> "$LOG_FILE" 2>&1
        fi
    fi
else
    # Container is not running, trigger full deployment
    log_message "Container $CONTAINER_NAME is not running. Triggering deployment..."
    cd "$SCRIPT_DIR" && bash deploy.sh >> "$LOG_FILE" 2>&1
    
    if [ $? -eq 0 ]; then
        log_message "Deployment completed successfully."
    else
        log_message "Deployment failed. Check logs for details."
    fi
fi
