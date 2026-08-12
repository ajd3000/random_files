#!/bin/bash

# Print sorted profile names to stdout.
_aws_switch_profiles() {
    aws configure list-profiles 2>/dev/null | sort
}

# Interactive picker: fzf if available (scrollable/filterable), else bash select.
# Selected name goes to stdout; prompts/menus go to stderr.
_aws_switch_pick_profile() {
    local profiles selected
    local -a profile_array
    profiles="$(_aws_switch_profiles)"
    if [[ -z "$profiles" ]]; then
        echo "No AWS profiles found in ~/.aws/config" >&2
        return 1
    fi

    if command -v fzf >/dev/null 2>&1; then
        echo "$profiles" | fzf \
            --height=80% \
            --reverse \
            --prompt="AWS profile> " \
            --header="Type to filter · Enter to select · Esc to cancel"
        return $?
    fi

    echo "Available AWS profiles:" >&2
    mapfile -t profile_array <<< "$profiles"
    PS3="Select profile number (q to cancel): "
    select selected in "${profile_array[@]}"; do
        if [[ "$REPLY" == "q" || "$REPLY" == "Q" ]]; then
            return 1
        fi
        if [[ -n "$selected" ]]; then
            echo "$selected"
            return 0
        fi
        echo "Invalid selection. Enter a number from the list, or q to cancel." >&2
    done
    return 1
}

_aws_switch_list_profiles() {
    echo "Available AWS profiles:"
    _aws_switch_profiles
}

_aws_switch_cleanup() {
    unset -f _aws_switch_profiles _aws_switch_pick_profile \
        _aws_switch_list_profiles _aws_switch_cleanup 2>/dev/null || true
}

# --- argument handling ---
PROFILE_NAME=""

if [[ $# -eq 0 ]]; then
    if [[ -t 0 ]]; then
        PROFILE_NAME="$(_aws_switch_pick_profile)" || {
            echo "Cancelled." >&2
            _aws_switch_cleanup
            return 1 2>/dev/null || exit 1
        }
    else
        # Non-interactive (piped/CI): list only, do not attempt a menu.
        _aws_switch_list_profiles
        _aws_switch_cleanup
        return 0 2>/dev/null || exit 0
    fi
elif [[ "$1" == "--list" || "$1" == "-l" ]]; then
    _aws_switch_list_profiles
    _aws_switch_cleanup
    return 0 2>/dev/null || exit 0
elif [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: source $0 [profile-name]"
    echo "       source $0              # interactive profile picker"
    echo "       $0 --list              # print profiles and exit"
    echo "Example: source $0 APX-Aptexx"
    _aws_switch_cleanup
    return 0 2>/dev/null || exit 0
else
    PROFILE_NAME=$1
fi

if [[ -z "$PROFILE_NAME" ]]; then
    echo "No profile selected." >&2
    _aws_switch_cleanup
    return 1 2>/dev/null || exit 1
fi

# Check if AWS SSO session is valid
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "AWS SSO session expired or not valid. Logging in..."
    aws sso login --sso-session inhabit-sso
fi

# Clear existing AWS credentials
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE

# Set the new profile
export AWS_PROFILE=$PROFILE_NAME

# Verify the switch
echo "Switching to profile: $PROFILE_NAME"
aws sts get-caller-identity

echo "To switch to this profile again, run: source ./aws-switch-account.sh $PROFILE_NAME"

_aws_switch_cleanup
