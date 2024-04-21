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
NAMESPACE="sre"
DEPLOYMENT_NAME="swype-app"
MAX_RESTARTS=3
LOG_FILE="./swype_monitoring.log"
LOG_DURATION_DAYS=7

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
  until kubectl "$@"; do
    count=$(($count + 1))
    if [ $count -ge $retries ]; then
      log "Command failed after $retries attempts: kubectl $*"
      return 1
    fi
    log "Attempt $count failed! Retrying in $delay seconds..."
    sleep $delay
  done
  return 0
}

# Main monitoring loop
while true; do
  manage_logs
  
  # Get the restart count of pods
  POD_RESTART_COUNT=$(kubectl_retry get pods --namespace="$NAMESPACE" -l app=$DEPLOYMENT_NAME -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}' | awk '{s+=$1} END {print s}')
  POD_RESTART_COUNT=${POD_RESTART_COUNT:-0}
  
  log "Current restart count for $DEPLOYMENT_NAME: $POD_RESTART_COUNT"
  
  if [ "$POD_RESTART_COUNT" -gt "$MAX_RESTARTS" ]; then
    log "Restart limit exceeded. Scaling down the deployment..."
    if ! kubectl_retry scale deployment/$DEPLOYMENT_NAME --replicas=0 --namespace="$NAMESPACE"; then
      log "Error scaling down deployment, will retry..."
      continue  # Continue the loop to retry the operation
    fi
    
    log "Checking for network-related issues..."
    kubectl_retry get events --namespace "$NAMESPACE" -o custom-columns=TIME:.lastTimestamp,MESSAGE:.message | grep -i "network"
    log "Deployment scaled down due to excessive restarts. Monitoring halted."
    break
  else
    log "Restart count within limits. Checking again in 60 seconds..."
  fi
  
  sleep 60
done

log "Script completed."