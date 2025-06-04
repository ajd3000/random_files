#!/bin/bash

# Function to display usage instructions
show_usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --profile PROFILE    AWS profile to use (required)"
    echo "  --domain DOMAIN      Specific domain to export (optional)"
    echo ""
    echo "Examples:"
    echo "  $0 --profile iiq-scp                    # Export all domains using iiq-scp profile"
    echo "  $0 --profile ANY-Prod                   # Export all domains using ANY-Prod profile"
    echo "  $0 --profile LMP-WordPress-Custom-Domains-Prod --domain example.com.au  # Export specific domain"
    echo ""
    echo "Note: The script will create CSV files containing DNS records for the specified domain(s)."
    echo "      Each CSV file will be named after its domain (e.g., example.com.au.csv)"
    exit 1
}

# Default profile
PROFILE=""
DOMAIN=""

# Check if no arguments were provided
if [ $# -eq 0 ]; then
    show_usage
fi

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    --domain)
      DOMAIN="$2"
      shift 2
      ;;
    --help|-h)
      show_usage
      ;;
    *)
      echo "Unknown option: $1"
      show_usage
      ;;
  esac
done

# Check if profile is provided
if [ -z "$PROFILE" ]; then
    echo "Error: --profile is required"
    show_usage
fi

echo "Using AWS Profile: $PROFILE"
if [ -n "$DOMAIN" ]; then
  echo "Filtering for domain: $DOMAIN"
fi

# Fetch hosted zones
echo "Fetching hosted zones..."
HOSTED_ZONES=$(aws route53 list-hosted-zones --profile "$PROFILE" --query "HostedZones[*].{Id:Id, Name:Name}" --output json)

# Check if we got any hosted zones
if [ -z "$HOSTED_ZONES" ]; then
  echo "Error: No hosted zones found or AWS CLI command failed"
  exit 1
fi

echo "Found hosted zones:"
echo "$HOSTED_ZONES" | jq -r '.[].Name'

# Create an associative array to track name occurrences
declare -A NAME_COUNT

# Iterate over each hosted zone
echo "$HOSTED_ZONES" | jq -c '.[]' | while read -r zone; do
  # Extract the Hosted Zone ID and Name
  ZONE_ID=$(echo "$zone" | jq -r '.Id' | sed 's|/hostedzone/||')
  ZONE_NAME=$(echo "$zone" | jq -r '.Name' | sed 's|\.$||')

  echo "Processing zone: $ZONE_NAME (ID: $ZONE_ID)"

  # Skip if domain is specified and doesn't match
  if [ -n "$DOMAIN" ] && [ "$ZONE_NAME" != "$DOMAIN" ]; then
    echo "Skipping $ZONE_NAME (doesn't match specified domain)"
    continue
  fi

  # Increment the counter for the current zone name
  NAME_COUNT["$ZONE_NAME"]=$((NAME_COUNT["$ZONE_NAME"]+1))

  # Generate a unique filename
  FILENAME="${ZONE_NAME}"
  if [ ${NAME_COUNT["$ZONE_NAME"]} -gt 1 ]; then
    FILENAME="${FILENAME}${NAME_COUNT["$ZONE_NAME"]}"
  fi
  FILENAME="${FILENAME}.csv"

  echo "Creating file: $FILENAME"

  # Fetch the resource record sets for the hosted zone in JSON format
  echo "Fetching records for $ZONE_NAME..."
  aws route53 list-resource-record-sets --profile "$PROFILE" --hosted-zone-id "$ZONE_ID" --output json > "${FILENAME}.json"

  # Check if the JSON file was created successfully
  if [ ! -f "${FILENAME}.json" ]; then
    echo "Error: Failed to create JSON file for $ZONE_NAME"
    continue
  fi

  # Convert the JSON output to CSV using jq
  echo "Converting to CSV..."
  jq -r '
   ["Name", "Type", "TTL", "ResourceRecords"],
   ( .ResourceRecordSets[] | [
     .Name,
     .Type,
     .TTL,
     (if .ResourceRecords then (.ResourceRecords[] | .Value) else "" end)
   ]) | @csv
  ' "${FILENAME}.json" > "${FILENAME}"

  # Check if the CSV file was created successfully
  if [ ! -f "${FILENAME}" ]; then
    echo "Error: Failed to create CSV file for $ZONE_NAME"
  else
    echo "Successfully created $FILENAME"
  fi

  # Clean up the temporary JSON file
  rm "${FILENAME}.json"

  echo "Completed processing $ZONE_NAME"
  echo "----------------------------------------"
done
