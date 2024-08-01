#!/bin/bash

# Fetch hosted zones
HOSTED_ZONES=$(aws route53 list-hosted-zones --profile iiq-scp --query "HostedZones[*].{Id:Id, Name:Name}" --output json)

# Create an associative array to track name occurrences
declare -A NAME_COUNT

# Iterate over each hosted zone
echo "$HOSTED_ZONES" | jq -c '.[]' | while read -r zone; do
  # Extract the Hosted Zone ID and Name
  ZONE_ID=$(echo "$zone" | jq -r '.Id' | sed 's|/hostedzone/||')
  ZONE_NAME=$(echo "$zone" | jq -r '.Name' | sed 's|\.$||')
        
  # Increment the counter for the current zone name
  NAME_COUNT["$ZONE_NAME"]=$((NAME_COUNT["$ZONE_NAME"]+1))
	    
  # Generate a unique filename
  FILENAME="${ZONE_NAME}"
  if [ ${NAME_COUNT["$ZONE_NAME"]} -gt 1 ]; then
    FILENAME="${FILENAME}${NAME_COUNT["$ZONE_NAME"]}"
  fi
    FILENAME="${FILENAME}.csv"
				  
  # Fetch the resource record sets for the hosted zone in JSON format
  aws route53 list-resource-record-sets --profile iiq-scp --hosted-zone-id "$ZONE_ID" --output json > "${FILENAME}.json"
				      
  # Convert the JSON output to CSV using jq
  jq -r '
   ["Name", "Type", "TTL", "ResourceRecords"],
   ( .ResourceRecordSets[] | [
     .Name,
     .Type,
     .TTL,
     (if .ResourceRecords then (.ResourceRecords[] | .Value) else "" end)
   ]) | @csv
  ' "${FILENAME}.json" > "${FILENAME}"
					        
  # Clean up the temporary JSON file
  rm "${FILENAME}.json"
						    
  echo "Saved records for $ZONE_NAME in $FILENAME"
done

