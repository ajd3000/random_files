#!/bin/bash

# List all Security Groups
security_groups=$(aws ec2 describe-security-groups --profile iiq-pyr --region us-east-2 --query 'SecurityGroups[*].GroupId' --output text)

# Loop through each security group
for sg in $security_groups
do
	# Get details for the security group
	details=$(aws ec2 describe-security-groups --group-ids --profile iiq-pyr --region us-east-2 $sg)

	# Save details to a file named after the security group ID
	echo "$details" > "PYR-${sg}.json"

	echo "Details saved for security group $sg"
done
