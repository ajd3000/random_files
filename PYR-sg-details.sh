#!/bin/bash

# Ensure jq is installed
if ! command -v jq &> /dev/null
then
   echo "jq could not be found. Please install jq to run this script."
   exit
fi

# List all security groups and store their IDs in a variable
security_groups=$(aws ec2 describe-security-groups --profile iiq-pyr --region us-east-2 --query 'SecurityGroups[*].GroupId' --output text)
echo "Security Groups: $security_groups"

# Loop through each security group ID
for sg_id in $security_groups; do
    echo "Processing Security Groups: $sg_id"

    # Get details of the security group
    sg_details=$(aws ec2 describe-security-groups --profile iiq-pyr --region us-east-2 --group-ids $sg_id --query 'SecurityGroups[*]' --output json)
    echo "Security Group Details: $sg_details"

    # Initialize CSV data
    csv_data="GroupId,GroupName,OwnerId,Description,IPProtocol,FromPort,ToPort,IpRange\n"
			    
    # Process each security group in the details
    echo "$sg_details" | jq -c '.[]' | while read -r row; do
        group_id=$(echo "$row" | jq -r '.GroupId')
        group_name=$(echo "$row" | jq -r '.GroupName')
        owner_id=$(echo "$row" | jq -r '.OwnerId')
        description=$(echo "$row" | jq -r '.Description')
	echo "Group ID: $group_id, Group Name: $group_name, Owner ID: $owner_id, Description: $description"

	# Check if there are any ingress rules
	ip_permissions_length=$(echo "$row" | jq '.IpPermissions | length')
	echo "Number of IpPermissions: $ip_permissions_length"

	if [[ $ip_permissions_length -gt 0 ]]; then
           # Process each ingress rule
           echo "$row" | jq -c '.IpPermissions[]' | while read -r ingress; do
               ip_protocol=$(echo "$ingress" | jq -r '.IpProtocol')
               from_port=$(echo "$ingress" | jq -r '.FromPort // empty')
               to_port=$(echo "$ingress" | jq -r '.ToPort // empty')
	       echo "Ingress - IP Protocol: $ip_protocol, From Port: $from_port, To Port: $to_port"

	       # Check if there are any IP ranges
	       ip_ranges_length=$(echo "$ingress" | jq '.IpRanges | length')
	       echo "Number of IpRanges: $ip_ranges_length"

	       if [[ $ip_ranges_length -gt 0 ]]; then
                   # Process each IP range
	           echo "$ingress" | jq -c '.IpRanges[]' | while read -r ip_range; do
                       ip_cidr=$(echo "$ip_range" | jq -r '.CidrIp')
		       echo "IP Range: $ip_cidr"
                       csv_data+="$group_id,$group_name,$owner_id,$description,$ip_protocol,$from_port,$to_port,$ip_cidr\n"
                   done
	       else
		   csv_data+="$group_id,$group_name,$owner_id,$description,$ip_protocol,$from_port,$to_port,\n"
	       fi
           done
        else
	    csv_data+="$group_id,$group_name,$owner_id,$description,,,,\n"
	fi
    done																										        
    # Save to a CSV file
    echo -e "$csv_data"
    echo -e "$csv_data" > "PYR-${sg_id}.csv"
    echo "Saved CSV data to PYR-${sg_id}.csv"
done
