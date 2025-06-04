#!/bin/bash

# Print CSV header
echo "Username,Access,Groups,Permissions"

# Get all IAM users
users=$(aws iam list-users --query 'Users[*].UserName' --output text)

for user in $users; do
    # Get user's access keys
    access_keys=$(aws iam list-access-keys --user-name "$user" --query 'AccessKeyMetadata[*].Status' --output text)
    has_active_keys=$(echo "$access_keys" | grep -q "Active" && echo "true" || echo "false")
    has_inactive_keys=$(echo "$access_keys" | grep -q "Inactive" && echo "true" || echo "false")

    # Get user's password status
    password_status=$(aws iam get-login-profile --user-name "$user" 2>/dev/null)
    has_password=$([ -n "$password_status" ] && echo "true" || echo "false")

    # Determine access type
    access_type="No credentials"
    if [ "$has_password" = "true" ] && [ "$has_active_keys" = "true" ]; then
        access_type="Password and active access keys"
    elif [ "$has_password" = "true" ] && [ "$has_inactive_keys" = "true" ]; then
        access_type="Password and inactive access keys"
    elif [ "$has_password" = "true" ]; then
        access_type="Password only"
    elif [ "$has_active_keys" = "true" ]; then
        access_type="Access keys - active"
    elif [ "$has_inactive_keys" = "true" ]; then
        access_type="Access keys - inactive"
    fi

    # Get user's groups
    groups=$(aws iam list-groups-for-user --user-name "$user" --query 'Groups[*].GroupName' --output text)
    if [ -z "$groups" ]; then
        groups="none"
    fi

    # Get permissions for each group
    permissions=""
    if [ "$groups" != "none" ]; then
        for group in $groups; do
            group_policies=$(aws iam list-attached-group-policies --group-name "$group" --query 'AttachedPolicies[*].PolicyName' --output text)
            if [ -n "$group_policies" ]; then
                if [ -n "$permissions" ]; then
                    permissions="$permissions; $group_policies"
                else
                    permissions="$group_policies"
                fi
            fi
        done
    fi

    # Get user-attached managed policies
    user_managed_policies=$(aws iam list-attached-user-policies --user-name "$user" --query 'AttachedPolicies[*].PolicyName' --output text)
    if [ -n "$user_managed_policies" ]; then
        if [ -n "$permissions" ]; then
            permissions="$permissions; $user_managed_policies"
        else
            permissions="$user_managed_policies"
        fi
    fi

    # Get user inline policies
    user_inline_policies=$(aws iam list-user-policies --user-name "$user" --query 'PolicyNames' --output text)
    if [ -n "$user_inline_policies" ]; then
        if [ -n "$permissions" ]; then
            permissions="$permissions; $user_inline_policies (inline)"
        else
            permissions="$user_inline_policies (inline)"
        fi
    fi

    if [ -z "$permissions" ]; then
        permissions="none"
    fi

    # Output as CSV, quoting fields to handle spaces/commas
    echo "\"$user\",\"$access_type\",\"$groups\",\"$permissions\""
done
