#!/bin/bash

# Title: Kubernetes Deployment Monitor
# Description: Monitors Kubernetes deployments for excessive restarts and manages log file sizes.
# Author: Jose Lima
# Date: April 21, 2024
# Version: 1.0
# Usage: Run this script to monitor specific Kubernetes deployments within the specified sre namespace. 
#        Adjust variables as necessary to fit the deployment specifics.
#
# Additional Notes:
# This script is intended for use in environments where deployments might be sensitive to frequent restarts
# and require immediate action to prevent service disruption. It includes log rotation and cleanup to
# maintain a sustainable disk usage over time.
#
# This script monitors a Kubernetes deployment for excessive pod restarts. It scales down the deployment
# if the restart count exceeds a specified threshold and manages log files to prevent disk space issues.
# It is designed to run continuously, checking the pod restart count every minute.

# Define variables
NAMESPACE="sre"                  # Kubernetes namespace where the deployment is located
DEPLOYMENT_NAME="swype-app"      # Name of the deployment (aaplication) to monitor
MAX_RESTARTS=3                   # Maximum allowed restarts before taking action
LOG_FILE="./swype_monitoring.log"  # Path to the log file
LOG_DURATION_DAYS=7              # Number of days to retain old log files

# Function: log
# Description: Logs a message with a timestamp to both the console and a log file.
# Parameters:
#   $1 - The message to log
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" | tee -a $LOG_FILE
}

# Function: manage_logs
# Description: Manages log file rotation and cleanup. It rotates the current log file if it exceeds 1MB
# and deletes log files older than the specified retention period.
manage_logs() {
  # Rotate the current log file if it exists and is larger than 1MB
  if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -ge 1048576 ]; then
    mv "$LOG_FILE" "$LOG_FILE.old"
    touch "$LOG_FILE"
    log "Log file was rotated."
  fi

  # Clean up old logs that exceed the retention period
  find ./ -name 'swype_monitoring.log.old*' -mtime +$LOG_DURATION_DAYS -exec rm {} \;
  log "Old log files cleaned up."
}

# Function: kubectl_retry
# Description: Executes a kubectl command with retries on failure.
# Parameters:
#   $@ - The kubectl command and its arguments
kubectl_retry() {
  local retries=3
  local count=0
  local delay=10
  local cmd_status=0

  until kubectl "$@"; do
    cmd_status=$?
    count=$(($count + 1))
    if [ $count -ge $retries ]; then
      log "Comand failed after $retries attempts: kubectl $*"
      return $cmd_status
    fi
    log "Attempt $count failed! Retying in $delay seconds..."
    sleep $delay
  done
}

# Main monitoring loop
while true; do
  manage_logs  # Manage log files at the start of each loop

  # Get the restart count of pods in the deployment
  POD_RESTART_COUNT=$(kubectl_retry get pods --namespace="$NAMESPACE" -l app=$DEPLOYMENT_NAME -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}' | awk '{s+=$1} END {print s}')
  if [ $? -ne 0 ]; then
    log "Error fetching pod restart count, will retry..."
    sleep 60
    continue
  fi

  log "Current restart count for $DEPLOYMENT_NAME: $POD_RESTART_COUNT"

# Take action if the restart limit is exceeded
# Ensure POD_RESTART_COUNT has a numeric value, defaulting to 0 if unset
POD_RESTART_COUNT=${POD_RESTART_COUNT:-0}

# Check if the restart count exceeds the maximum allowed restarts
if [ "$POD_RESTART_COUNT" -gt "$MAX_RESTARTS" ]; then
    log "Restart limit exceeded. Scaling down the deployment..."
    
    # Attempt to scale down the deployment
    if ! kubectl_retry scale deployment/$DEPLOYMENT_NAME --replicas=0 --namespace="$NAMESPACE"; then
        log "Error scaling down deployment, will retry..."
        continue  # Continue the loop to retry the operation
    fi
fi

    log "Checking for network-related issues..."
    kubectl_retry get events --namespace "$NAMESPACE" -o custom-columns=TIME:.lastTimestamp,MESSAGE:.message | grep -i "network"
    log "Deployment scaled down due to excessive restarts. Monitoring halted."
    break
  else
    log "Restart count within limits. Checking again in 60 seconds..."
  fi

  sleep 60  # Wait for 60 seconds before the next check
done

log "Script completed."