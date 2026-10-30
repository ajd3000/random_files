#!/bin/bash

# Replace with your Cloudflare authentication details
CF_API_EMAIL=""
CF_API_KEY=""

# Replace with the email of the user you want to remove
USER_EMAIL="example@gmail.com"

# Cloudflare API endpoints
LIST_ACCOUNTS_ENDPOINT="https://api.cloudflare.com/client/v4/accounts?page=1&per_page=1000"
LIST_MEMBERS_ENDPOINT="https://api.cloudflare.com/client/v4/accounts/%s/members"
REMOVE_MEMBER_ENDPOINT="https://api.cloudflare.com/client/v4/accounts/%s/members/%s"

# Initialize success and fail counters
success_count=0
fail_count=0

# Fetch all accounts
accounts_response=$(curl -s -X GET "$LIST_ACCOUNTS_ENDPOINT" \
    -H "X-Auth-Email: $CF_API_EMAIL" \
    -H "X-Auth-Key: $CF_API_KEY" \
    -H "Content-Type: application/json")

# Extract account IDs using jq
account_ids=$(echo "$accounts_response" | jq -r '.result[].id')

# Check if account IDs were fetched correctly
if [ -z "$account_ids" ]; then
    echo "Failed to fetch account IDs."
    exit 1
fi

# Loop through each account to find and remove the user by email
for account_id in $account_ids; do

    # Fetch members of the current account
    members_response=$(curl -s -X GET $(printf "$LIST_MEMBERS_ENDPOINT" "$account_id") \
        -H "X-Auth-Email: $CF_API_EMAIL" \
        -H "X-Auth-Key: $CF_API_KEY" \
        -H "Content-Type: application/json")

    # Find the user ID by email (specifically capture the first occurrence)
    USER_ID=$(echo "$members_response" | jq -r --arg email "$USER_EMAIL" '.result[] | select(.user.email == $email) | .id' | head -n 1)

    # Check if the user ID was found
    if [ -n "$USER_ID" ]; then

        # Remove user from the account
        remove_response=$(curl -s -X DELETE $(printf "$REMOVE_MEMBER_ENDPOINT" "$account_id" "$USER_ID") \
            -H "X-Auth-Email: $CF_API_EMAIL" \
            -H "X-Auth-Key: $CF_API_KEY" \
            -H "Content-Type: application/json")

        # Check if the removal was successful
        if echo "$remove_response" | grep -q '"success":true'; then
            echo "Successfully removed user $USER_EMAIL from account $account_id."
            ((success_count++))
        else
            echo "Failed to remove user $USER_EMAIL from account $account_id."
            ((fail_count++))
        fi
    else
        echo "User $USER_EMAIL not found in account $account_id."
        ((fail_count++))
    fi
done

# Print the final counts
echo "Process completed."
echo "Success count: $success_count"
echo "Fail count: $fail_count"
