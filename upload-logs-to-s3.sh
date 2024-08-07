#!/bin/bash

LOG_FILE="/var/log/upload-logs-to-s3.log"

# Function to fetch meta-data
fetch_metadata() {
        local METADATA_URL="http://169.254.169.254/latest/meta-data/$1"
        curl -s $METADATA_URL
}

# Fetch instance ID

INSTANCE_ID=$(fetch_metadata "instance-id")
if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" == "/" ]; then
        echo "$(date): Error: Unable to fetch instance ID" >> $LOG_FILE
        exit 1
else
        echo "$(date): Fetched Instance ID: $INSTANCE_ID" >> $LOG_FILE
fi

# Fetch the current date
DATE=$(date +%Y%m%d)
S3_BUCKET="s3://ad-test-logs/system-logs"

# Function to upload a log file to S3
upload_log() {
     local LOG_PATH=$1
     local LOG_NAME=$(basename $LOG_PATH)
     aws s3 cp $LOG_PATH $S3_BUCKET/$INSTANCE_ID/$DATE/$LOG_NAME
     if [ $? -ne 0 ]; then
             echo "$(date): Error uploading $LOG_PATH" >> $LOG_FILE
     else
             echo "$(date): Successfully uploaded4log-path" >> $LOG_FILE
     fi
}

# Upload logs
upload_log /var/log/auth.log
upload_log /var/log/syslog

echo "$(date): Logs uploaded successfully." >> $LOG_FILE
