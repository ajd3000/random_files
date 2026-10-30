#!/bin/bash

# Create a temporary directory for counters
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "${TEMP_DIR}"' EXIT

# Default values
DRY_RUN=false
VERBOSE=false
SKIP_CONFIRM=false

# Initialize counters in temporary files
echo "0" > "${TEMP_DIR}/success_count"
echo "0" > "${TEMP_DIR}/fail_count"
echo "0" > "${TEMP_DIR}/not_found_count"
echo "0" > "${TEMP_DIR}/processed_count"
echo "0" > "${TEMP_DIR}/skipped_count"

# Function to increment counter
increment_counter() {
    local counter_file="$1"
    local current_value=$(cat "${TEMP_DIR}/${counter_file}")
    echo $((current_value + 1)) > "${TEMP_DIR}/${counter_file}"
}

# Utility functions for logging
log() {
    local level=$1
    shift
    local message=$@
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message"
}

info() {
    log "INFO" "$@"
}

error() {
    log "ERROR" "$@" >&2
}

debug() {
    if [ "$VERBOSE" = true ]; then
        log "DEBUG" "$@"
    fi
}

# Function to check API response
check_response() {
    local response=$1
    local error_message=$2

    # First check if response is valid JSON
    if ! echo "$response" | jq -e . >/dev/null 2>&1; then
        error "$error_message: Invalid JSON response"
        debug "Raw response: $response"
        return 1
    fi

    # Then check for success field
    if ! echo "$response" | jq -e 'has("success")' >/dev/null; then
        error "$error_message: Unexpected API response format"
        debug "Raw response: $response"
        return 1
    fi

    if ! echo "$response" | jq -e '.success == true' >/dev/null; then
        local api_error=$(echo "$response" | jq -r '.errors[].message // "Unknown error"')
        error "$error_message: $api_error"
        debug "Full error response: $response"
        return 1
    fi
    return 0
}

# Function to check if account name is problematic
is_problematic_account() {
    local account_name="$1"
    # List of patterns to skip
    [[ "$account_name" == *"@"* ]] || # Contains @ symbol
    [[ "$account_name" == *"'"* ]] || # Contains apostrophe
    [[ "$account_name" =~ Account$ ]]  # Ends with "Account"
}
# Modified usage function
usage() {
    cat << EOF
Usage: $(basename $0) [OPTIONS] [COMMAND]
Manage users in Cloudflare accounts.

Commands:
    add     Add user to accounts
    remove  Remove user from accounts
    modify  Modify user roles in accounts

Options:
    -e, --email EMAIL      Email of the user to add/remove/modify
    -t, --token TOKEN      Cloudflare API token
    -r, --roles LIST      Comma-separated list of role names (required for add/modify)
                         Example: "Administrator,DNS,Billing"
                         Note: Role names containing commas are handled automatically
                         Example: "DNS,SSL/TLS, Caching, Performance, Page Rules, and Customization"
    -a, --accounts LIST    Comma-separated list of account domains (optional)
                         If not specified, applies to all accounts
    -d, --dry-run         Show what would be done without making changes
    -y, --yes             Skip confirmation prompts
    -h, --help            Show this help message
    -v, --verbose         Enable verbose output
    -l, --list-roles      List all available roles and exit

Examples:
    $(basename $0) add -e user@example.com -t your-api-token -r "Administrator,DNS"
    $(basename $0) modify -e user@example.com -t your-api-token -r "Administrator"
    $(basename $0) remove -e user@example.com -t your-api-token
    $(basename $0) --list-roles
EOF
    exit 1
}

# Function to list all available roles
list_roles() {
    cat << EOF
Available Roles:
    Administrator
    Administrator Read Only
    Analytics
    API Gateway
    API Gateway Read
    Audit Logs Viewer
    Billing
    Bot Management (Account-Wide)
    Cloudflare Access
    Cloudflare DEX
    Cloudflare Gateway
    Cloudflare Images
    Cloudflare R2 Admin
    Cloudflare R2 Read
    Cloudflare Stream
    Cloudflare Workers Admin
    Cloudflare Zero Trust
    Cloudflare Zero Trust PII
    Cloudflare Zero Trust Read Only
    Cloudflare Zero Trust Reporting
    DNS
    Email Configuration Admin
    Email Integration Admin
    Email Security Analyst
    Email Security Readonly
    Email Security Reporting
    Firewall
    HTTP Applications
    HTTP Applications Read
    Hyperdrive Admin
    Hyperdrive Readonly
    Load Balancer
    Log Share
    Log Share Reader
    Magic Network Monitoring
    Magic Network Monitoring Admin
    Magic Network Monitoring Read-Only
    Minimal Account Access
    Network Services (Magic)
    Network Services (Magic, Read-Only)
    Page Shield
    Page Shield Read
    SSL/TLS, Caching, Performance, Page Rules, and Customization
    Super Administrator - All Privileges
    Trust And Safety
    Turnstile
    Turnstile Read
    Vectorize Admin
    Vectorize Readonly
    Waiting Room Admin
    Waiting Room Read
    Zaraz Admin
    Zaraz Edit
    Zaraz Read
    Zone Versioning (Account-Wide)
    Zone Versioning Read (Account-Wide)
EOF
    exit 0
}
# Role ID mapping
declare -A ROLE_IDS=(
    ["Administrator"]="05784afa30c1afe1440e79d9351c7430"
    ["Administrator Read Only"]="f2b20eaa1a5d4af42b53ac16238c99c7"
    ["Analytics"]="6ddc5f80969d01105b5a0931e0079365"
    ["API Gateway"]="67ff895d0db461b61dd911232fcbc790"
    ["API Gateway Read"]="35956457e745b2af7331713a1ddf4fdb"
    ["Audit Logs Viewer"]="9dfa4d1b73034f70ad896bf1c26d78f3"
    ["Billing"]="298ce8e7a2ba08b9d18ce0a32bb458ee"
    ["Bot Management (Account-Wide)"]="17f13fba9173af84903c2be2b56240e5"
    ["Cloudflare Access"]="951e083054cc4f172986fc9be0aa17af"
    ["Cloudflare DEX"]="9f436dc7d8294a34345b6a8dc83fdf71"
    ["Cloudflare Gateway"]="10e95af809390ce236cbdcf03935e215"
    ["Cloudflare Images"]="94bedef1a0bdd311891188867727e42d"
    ["Cloudflare R2 Admin"]="6f83464b634142ce4ac573616256096e"
    ["Cloudflare R2 Read"]="084b982fe42511d15feb1411e4c9ce9e"
    ["Cloudflare Stream"]="8b081b06f8ffef0522957fc6929cdcca"
    ["Cloudflare Workers Admin"]="57280df9f1a5806e04f065b07bbdd17a"
    ["Cloudflare Zero Trust"]="ef13f042efdd58f592148c035f291bfa"
    ["Cloudflare Zero Trust PII"]="f43d556e0699e47c9188ea1973a48e24"
    ["Cloudflare Zero Trust Read Only"]="156a872fa6df06e0e9b85d32afce6990"
    ["Cloudflare Zero Trust Reporting"]="b525e80fc64a4323a9ea666467d1865c"
    ["DNS"]="069fe803647ed3609e93d041d5df6050"
    ["Email Configuration Admin"]="70035ec03549c8799c170a2afc25c139"
    ["Email Integration Admin"]="43801681f525f111da3f15d07ffafdf1"
    ["Email Security Analyst"]="d9290f651ced29c9524b79aa5ac4fcaf"
    ["Email Security Readonly"]="3390240245b5d4d8be9f8c5789dca2d7"
    ["Email Security Reporting"]="dfed41846ee1b4952dbeec65c7195e31"
    ["Firewall"]="1963e6e3aca5ac9a7a91609a0040ab02"
    ["HTTP Applications"]="08abaa5235c2196d5f3daf457190161b"
    ["HTTP Applications Read"]="ecd163368eb6c45b880362b0c098f5e1"
    ["Hyperdrive Admin"]="fc86e6664bfb8ff279cd5a92f7424b50"
    ["Hyperdrive Readonly"]="75312cadbc1dce48bfcd654da1a2ce03"
    ["Load Balancer"]="c61d4237ab1c08a3d11feb6bd5e91c5a"
    ["Log Share"]="3a170f9cfd62f321d6d835dc44bfe6dc"
    ["Log Share Reader"]="340113a819900e1b4beebccc2ddb32e7"
    ["Magic Network Monitoring"]="6d7861f7d7d85b03272fd2b964190391"
    ["Magic Network Monitoring Admin"]="37a46bc5222ebb5577b2efc7fc467fb4"
    ["Magic Network Monitoring Read-Only"]="5c2cdbd23a00e169752f335bffc5988a"
    ["Minimal Account Access"]="5c35d2bf3a545e6b7560b826c0d23c39"
    ["Network Services (Magic)"]="e8307f861fd552343e8a582620da412e"
    ["Network Services (Magic, Read-Only)"]="6fd8c99c8a080a3a8f2b292c1515fb25"
    ["Page Shield"]="344b7dd765da5a9de6230f7540cabb20"
    ["Page Shield Read"]="1b20b8701ab8a22f0229ff1c831a9e27"
    ["SSL/TLS, Caching, Performance, Page Rules, and Customization"]="75f36071fa06ebfac6da0c3f8ddbc4df"
    ["Super Administrator - All Privileges"]="33666b9c79b9a5273fc7344ff42f953d"
    ["Trust And Safety"]="051312130d7384b97d7c4fa122eb7519"
    ["Turnstile"]="d4c68d56bf2ef665eb82994199a393fd"
    ["Turnstile Read"]="2964cc9c4ebefdc6bf2bdbc4e106b906"
    ["Vectorize Admin"]="89c48528394f516ff4ce47c39036cf12"
    ["Vectorize Readonly"]="2d805933d825eb7ee214b294ae7d2e43"
    ["Waiting Room Admin"]="87ce9ccd4a479a91edbf90747fd08c53"
    ["Waiting Room Read"]="629ae7e9cd43b305474cdecb23427234"
    ["Zaraz Admin"]="fc67f46f32917cf9f0bdc082198cd747"
    ["Zaraz Edit"]="4b48b09177b06a45f6224af13e7afaf3"
    ["Zaraz Read"]="69abc03715c77ae49be5e407f03d0650"
    ["Zone Versioning (Account-Wide)"]="973118f5c129494d4b7df026e598dce6"
    ["Zone Versioning Read (Account-Wide)"]="ccf93de592091ce5e210c816337a37d4"
)

# Function to validate roles and get their IDs
get_role_ids() {
    local roles_string="$1"
    local role_ids=""
    local remaining="$roles_string"
    local matched_roles=()

    # Remove surrounding quotes if present
    remaining=$(echo "$remaining" | sed -e 's/^"*//' -e 's/"*$//')
    local original_remaining="$remaining"

    # Get all role names sorted by length (longest first) to match complex names first
    # This ensures "SSL/TLS, Caching, Performance, Page Rules, and Customization"
    # matches before shorter substrings like "SSL/TLS"
    local sorted_roles=$(for role in "${!ROLE_IDS[@]}"; do
        echo "${#role}|$role"
    done | sort -t'|' -k1 -rn | cut -d'|' -f2-)

    # Try to match each role name in the input string (longest first)
    while IFS= read -r role; do
        # Check if this role name appears in the remaining string
        # Use a more precise match: role must be followed by comma, end of string, or whitespace
        if [[ "$remaining" =~ .*"$role".* ]]; then
            # Verify it's a valid role
            if [[ -n "${ROLE_IDS[$role]}" ]]; then
                # Check if we've already matched this role
                local already_matched=false
                for matched in "${matched_roles[@]}"; do
                    if [[ "$matched" == "$role" ]]; then
                        already_matched=true
                        break
                    fi
                done

                if [ "$already_matched" = false ]; then
                    matched_roles+=("$role")
                    debug "Found role: '$role'"

                    # Remove the matched role from remaining string using bash string manipulation
                    # This handles role names with commas correctly
                    if [[ "$remaining" == *"$role"* ]]; then
                        # Find the position of the role in the string
                        local before="${remaining%%"$role"*}"
                        local after="${remaining#*"$role"}"

                        # Remove leading/trailing commas and quotes from the parts
                        before=$(echo "$before" | sed -e 's/[[:space:],]*$//')
                        after=$(echo "$after" | sed -e 's/^[[:space:],]*//')

                        # Reconstruct remaining, handling comma between parts
                        if [[ -n "$before" && -n "$after" ]]; then
                            remaining="${before},${after}"
                        elif [[ -n "$before" ]]; then
                            remaining="$before"
                        elif [[ -n "$after" ]]; then
                            remaining="$after"
                        else
                            remaining=""
                        fi

                        # Clean up any double commas or trailing/leading commas
                        remaining=$(echo "$remaining" | sed -e 's/,[[:space:]]*,/,/g' -e 's/^[[:space:],]*//' -e 's/[[:space:],]*$//')
                    fi
                fi
            fi
        fi
    done <<< "$sorted_roles"

    # Build the role_ids string from matched roles
    for role in "${matched_roles[@]}"; do
        if [ -n "$role_ids" ]; then
            role_ids="${role_ids},"
        fi
        role_ids="${role_ids}${ROLE_IDS[$role]}"
        debug "Added role ID for '$role': ${ROLE_IDS[$role]}"
    done

    # Check if we have any remaining unmatched text (allowing only whitespace and commas)
    remaining=$(echo "$remaining" | sed -e 's/^[[:space:],]*//' -e 's/[[:space:],]*$//')
    if [[ -n "$remaining" ]]; then
        error "Invalid role or unmatched text: '$remaining'"
        error "Original input: '$original_remaining'"
        info "Use --list-roles to see available roles"
        info "Note: When specifying multiple roles, separate them with commas: 'Role1,Role2'"
        return 1
    fi

    if [ -z "$role_ids" ]; then
        error "No valid roles found in: $roles_string"
        info "Use --list-roles to see available roles"
        return 1
    fi

    echo "$role_ids"
    return 0
}
# Function to add user to an account
add_user_to_account() {
    local account_id="$1"
    local account_name="$2"
    local email="$3"
    local role_ids="$4"
    local safe_account_name=$(echo "$account_name" | sed 's/[^[:alnum:][:space:].-]/_/g')

    debug "Adding user to account: $safe_account_name"

    # Prepare the JSON payload
    local payload=$(cat <<EOF
{
    "email": "$email",
    "status": "accepted",
    "roles": [$(echo "$role_ids" | sed 's/,/","/g' | sed 's/\(.*\)/"\1"/')]
}
EOF
)

    debug "Request payload: $payload"

    if [ "$DRY_RUN" = true ]; then
        info "DRY RUN: Would add user $email to account $safe_account_name with roles: $role_ids"
        return 0
    fi

    # Make the API call to add the user
    local response=$(curl -s -X POST \
        "https://api.cloudflare.com/client/v4/accounts/${account_id}/members" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload")

    # Check if response is valid JSON
    if ! echo "$response" | jq -e . >/dev/null 2>&1; then
        error "Invalid JSON response from add operation for account $safe_account_name"
        debug "Raw response: $response"
        return 1
    fi

    # Check for success
    if echo "$response" | jq -e '.success == true' >/dev/null; then
        info "Successfully added user to account $safe_account_name"
        return 0
    else
        local error_msg=$(echo "$response" | jq -r '.errors[].message // "Unknown error"')
        error "Failed to add user to $safe_account_name: $error_msg"
        debug "Full error response: $response"
        return 1
    fi
}

# Function to find and delete user from an account
find_and_delete_user() {
    local account_id="$1"
    local account_name="$2"
    local target_email="$3"
    local member_id=""
    local response
    local all_members=""
    local safe_account_name=$(echo "$account_name" | sed 's/[^[:alnum:][:space:].-]/_/g')

    debug "Checking account: $safe_account_name ($account_id)"

    # Get account members with pagination
    local page=1
    local per_page=50

    while true; do
        debug "Fetching page $page of members for account $safe_account_name"
        response=$(curl -s -X GET \
            "https://api.cloudflare.com/client/v4/accounts/${account_id}/members?page=${page}&per_page=${per_page}" \
            -H "Authorization: Bearer ${TOKEN}")

        # Check if response is valid JSON
        if ! echo "$response" | jq -e . >/dev/null 2>&1; then
            error "Invalid JSON response from API for account $safe_account_name"
            debug "Raw response: $response"
            return 1
        fi

        # Check for authentication errors specifically
        if echo "$response" | jq -e '.errors[] | select(.code == 9103 or .message | contains("Authentication"))' >/dev/null; then
            debug "No access to account $safe_account_name (Authentication error)"
            return 3  # New return code for auth errors
        fi

        # Check for other API errors
        if ! echo "$response" | jq -e '.success == true' >/dev/null; then
            error "API error for account $safe_account_name: $(echo "$response" | jq -r '.errors[].message // "Unknown error"')"
            debug "Full error response: $response"
            return 1
        fi

        # Append this page's results to all_members
        if [ -z "$all_members" ]; then
            all_members=$(echo "$response" | jq '.result')
        else
            all_members=$(echo "$all_members" "$response" | jq -s '.[0] + .[1].result')
        fi

        # Check if we've got all pages
        total_pages=$(echo "$response" | jq -r '.result_info.total_pages')
        debug "Found $total_pages total pages for account $safe_account_name"
        if [ "$page" -ge "$total_pages" ]; then
            break
        fi
        ((page++))
    done

    # Extract member ID for target email
    member_id=$(echo "$all_members" | jq -r --arg email "$target_email" \
        '.[] | select(.user.email == $email) | .id')

    if [ -n "$member_id" ]; then
        info "Found user in account $safe_account_name"

        if [ "$DRY_RUN" = true ]; then
            info "DRY RUN: Would delete user from account $safe_account_name"
            return 0
        fi

        # Delete the member
        delete_response=$(curl -s -X DELETE \
            "https://api.cloudflare.com/client/v4/accounts/${account_id}/members/${member_id}" \
            -H "Authorization: Bearer ${TOKEN}")

        if echo "$delete_response" | jq -e '.success == true' >/dev/null; then
            info "Successfully removed user from account $safe_account_name"
            return 0
        else
            error "Failed to remove user from $safe_account_name: $(echo "$delete_response" | jq -r '.errors[].message // "Unknown error"')"
            debug "Full error response: $delete_response"
            return 1
        fi
    else
        debug "User $target_email not found in account $safe_account_name"
        return 2
    fi
}

# function to modify user roles
modify_user_roles() {
    local account_id="$1"
    local account_name="$2"
    local target_email="$3"
    local role_ids="$4"
    local member_id=""
    local safe_account_name=$(echo "$account_name" | sed 's/[^[:alnum:][:space:].-]/_/g')

    debug "Checking account: $safe_account_name ($account_id)"
    debug "Role IDs received: $role_ids"

    # Get account members with pagination
    local page=1
    local per_page=50
    local all_members=""

    while true; do
        debug "Fetching page $page of members for account $safe_account_name"
        local response=$(curl -s -X GET \
            "https://api.cloudflare.com/client/v4/accounts/${account_id}/members?page=${page}&per_page=${per_page}" \
            -H "Authorization: Bearer ${TOKEN}")

        if ! check_response "$response" "Failed to fetch members for $safe_account_name"; then
            return 1
        fi

        # Append this page's results to all_members
        if [ -z "$all_members" ]; then
            all_members=$(echo "$response" | jq '.result')
        else
            all_members=$(echo "$all_members" "$response" | jq -s '.[0] + .[1].result')
        fi

        # Check if we've got all pages
        total_pages=$(echo "$response" | jq -r '.result_info.total_pages')
        debug "Found $total_pages total pages for account $safe_account_name"
        if [ "$page" -ge "$total_pages" ]; then
            break
        fi
        ((page++))
    done

    # Find member ID and current member object from the complete list of members
    local current_member=$(echo "$all_members" | jq -c --arg email "$target_email" \
        '.[] | select(.user.email == $email)')

    member_id=$(echo "$current_member" | jq -r '.id')

    if [ -z "$member_id" ]; then
        debug "User $target_email not found in account $safe_account_name"
        increment_counter "not_found_count"
        return 2
    fi

    debug "Found user in account $safe_account_name with member ID: $member_id"
    debug "Current member object: $current_member"

    # Check the current roles structure
    local current_roles=$(echo "$current_member" | jq -c '.roles // []')
    debug "Current roles structure: $current_roles"

    if [ "$DRY_RUN" = true ]; then
        info "DRY RUN: Would modify user roles in account $safe_account_name"
        increment_counter "success_count"
        return 0
    fi

    # Create the JSON payload
    # For PUT requests, try sending roles as objects with id fields
    # Build roles array as objects: [{"id":"role1"},{"id":"role2"}]
    local roles_json=""
    IFS=',' read -ra ROLE_ARRAY <<< "$role_ids"
    for role_id in "${ROLE_ARRAY[@]}"; do
        role_id=$(echo "$role_id" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if [ -n "$role_id" ]; then
            if [ -n "$roles_json" ]; then
                roles_json="${roles_json},"
            fi
            roles_json="${roles_json}{\"id\":\"${role_id}\"}"
        fi
    done

    local payload=$(cat <<EOF
{
    "status": "accepted",
    "roles": [${roles_json}]
}
EOF
)

    # Validate the payload is valid JSON before sending
    if ! echo "$payload" | jq -e . >/dev/null 2>&1; then
        error "Generated invalid JSON payload for account $safe_account_name"
        debug "Payload: $payload"
        debug "Role IDs: $role_ids"
        return 1
    fi

    # Validate that roles is an array (check if we can access first element)
    # This works even with older jq versions
    if ! echo "$payload" | jq -e '.roles[0]' >/dev/null 2>&1; then
        error "Roles field does not appear to be an array for account $safe_account_name"
        debug "Payload: $payload"
        debug "Role IDs: $role_ids"
        return 1
    fi

    debug "Request payload: $payload"
    debug "Role IDs: $role_ids"

    # Make the API call to update the roles
    # Use the EXACT same curl format as add_user_to_account function
    local update_response=$(curl -s -X PUT \
        "https://api.cloudflare.com/client/v4/accounts/${account_id}/members/${member_id}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload")

    debug "API Response: $update_response"

    if echo "$update_response" | jq -e '.success == true' >/dev/null; then
        info "Successfully updated user roles in account $safe_account_name"
        increment_counter "success_count"
        return 0
    else
        error "Failed to update user roles in $safe_account_name: $(echo "$update_response" | jq -r '.errors[].message // "Unknown error"')"
        debug "Full error response: $update_response"
        increment_counter "fail_count"
        return 1
    fi
}

# Parse command line arguments
COMMAND=""
ROLES=""
ACCOUNT_LIST=""

while [[ $# -gt 0 ]]; do
    case $1 in
        add|remove|modify)
            COMMAND="$1"
            shift
            ;;
        -e|--email)
            USER_EMAIL="$2"
            shift 2
            ;;
        -t|--token)
            TOKEN="$2"
            shift 2
            ;;
        -r|--roles)
            ROLES="$2"
            shift 2
            ;;
        -a|--accounts)
            ACCOUNT_LIST="$2"
            shift 2
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -y|--yes)
            SKIP_CONFIRM=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -l|--list-roles)
            list_roles
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required parameters
if [ -z "$COMMAND" ]; then
    error "Command (add/remove/modify) is required"
    usage
fi

if [ -z "$USER_EMAIL" ] || [ -z "$TOKEN" ]; then
    error "Email and token are required"
    usage
fi

if [ "$COMMAND" = "add" ] || [ "$COMMAND" = "modify" ]; then
    ROLE_IDS=$(get_role_ids "$ROLES")
    if [ $? -ne 0 ]; then
        exit 1
    fi
    # Remove any debug output and clean up the role ID
    ROLE_IDS=$(echo "$ROLE_IDS" | tail -n1 | tr -d '\n' | tr -d ' ')
    debug "Final role IDs: $ROLE_IDS"
fi

# Convert roles to role IDs if adding user
if [ "$COMMAND" = "add" ] || [ "$COMMAND" = "modify" ]; then
    ROLE_IDS=$(get_role_ids "$ROLES")
    if [ $? -ne 0 ]; then
        exit 1
    fi
    # Remove any debug output and quotes from ROLE_IDS
    ROLE_IDS=$(echo "$ROLE_IDS" | tail -n1 | tr -d '"')
    debug "Final role IDs: $ROLE_IDS"
fi

# Fetch all accounts
info "Fetching account list..."
accounts_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts?page=1&per_page=1000" \
    -H "Authorization: Bearer $TOKEN")

if ! check_response "$accounts_response" "Failed to fetch accounts"; then
    exit 1
fi

# Filter accounts if account list is provided
if [ -n "$ACCOUNT_LIST" ]; then
    debug "Filtering accounts to: $ACCOUNT_LIST"
    # Convert comma-separated list to array
    IFS=',' read -ra ACCOUNT_ARRAY <<< "$ACCOUNT_LIST"

    # Start with empty filtered accounts
    filtered_accounts=""

    # Loop through each account pattern
    for pattern in "${ACCOUNT_ARRAY[@]}"; do
        # Trim whitespace
        pattern=$(echo "$pattern" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        # Get matching accounts for this pattern
        matching_accounts=$(echo "$accounts_response" | jq -c --arg pattern "$pattern" \
            '.result[] | select(.name | contains($pattern))')

        # Append to filtered accounts
        if [ -n "$matching_accounts" ]; then
            if [ -n "$filtered_accounts" ]; then
                filtered_accounts=$(echo -e "${filtered_accounts}\n${matching_accounts}")
            else
                filtered_accounts="$matching_accounts"
            fi
        fi
    done

    # Count unique accounts
    total_accounts=$(echo "$filtered_accounts" | sort -u | wc -l)

    if [ "$total_accounts" -eq 0 ]; then
        error "No matching accounts found for patterns: $ACCOUNT_LIST"
        debug "Available accounts:"
        echo "$accounts_response" | jq -r '.result[].name' | while read -r name; do
            debug "  - $name"
        done
        exit 1
    fi

    # Remove any duplicates
    filtered_accounts=$(echo "$filtered_accounts" | sort -u)
else
    filtered_accounts=$(echo "$accounts_response" | jq -c '.result[]')
    total_accounts=$(echo "$accounts_response" | jq -r '.result | length')
fi

debug "Total accounts to process: $total_accounts"

# Confirm before proceeding
if [ "$SKIP_CONFIRM" = false ]; then
    if [ "$COMMAND" = "add" ]; then
        echo "About to add user $USER_EMAIL to $total_accounts accounts with roles: $ROLES"
    elif [ "$COMMAND" = "modify" ]; then
        echo "About to modify user $USER_EMAIL roles to: $ROLES in $total_accounts accounts"
    else
        echo "About to remove user $USER_EMAIL from $total_accounts accounts"
    fi
    read -p "Continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Operation cancelled by user"
        exit 0
    fi
fi

# Process accounts
echo "$filtered_accounts" | jq -c '.' | while read -r account; do
    {
        account_id=$(echo "$account" | jq -r '.id')
        account_name=$(echo "$account" | jq -r '.name')

        debug "Processing: $account_name"

        if [ -z "$account_id" ] || [ -z "$account_name" ]; then
            error "Invalid account data received"
            increment_counter "fail_count"
            continue
        fi

        if is_problematic_account "$account_name"; then
            info "Skipping problematic account: $account_name"
            increment_counter "skipped_count"
            continue
        fi

        case "$COMMAND" in
            "add")
                add_user_to_account "$account_id" "$account_name" "$USER_EMAIL" "$ROLE_IDS"
                result=$?
                ;;
            "remove")
                find_and_delete_user "$account_id" "$account_name" "$USER_EMAIL"
                result=$?
                ;;
            "modify")
                modify_user_roles "$account_id" "$account_name" "$USER_EMAIL" "$ROLE_IDS"
                result=$?
                ;;
        esac

        increment_counter "processed_count"

    } || {
        error "Unexpected error processing account $account_name"
        increment_counter "fail_count"
        increment_counter "processed_count"
    }
done

# Print final summary
success_count=$(cat "${TEMP_DIR}/success_count")
fail_count=$(cat "${TEMP_DIR}/fail_count")
not_found_count=$(cat "${TEMP_DIR}/not_found_count")
processed_count=$(cat "${TEMP_DIR}/processed_count")
skipped_count=$(cat "${TEMP_DIR}/skipped_count")

info "=== Process Summary ==="
info "Total accounts processed: $processed_count of $total_accounts"
if [ "$DRY_RUN" = true ]; then
    info "DRY RUN RESULTS:"
    case "$COMMAND" in
        add)
            info "  - Would add user to: $success_count accounts"
            info "  - Failed to check: $fail_count accounts"
            info "  - Skipped accounts: $skipped_count"
            ;;
        modify)
            info "  - Would modify roles in: $success_count accounts"
            info "  - User not found in: $not_found_count accounts"
            info "  - Failed to check: $fail_count accounts"
            info "  - Skipped accounts: $skipped_count"
            ;;
        remove)
            info "  - Would remove user from: $success_count accounts"
            info "  - User not found in: $not_found_count accounts"
            info "  - Failed to check: $fail_count accounts"
            info "  - Skipped accounts: $skipped_count"
            ;;
    esac
else
    info "EXECUTION RESULTS:"
    case "$COMMAND" in
        add)
            info "  - Successfully added to: $success_count accounts"
            info "  - Failed operations: $fail_count accounts"
            info "  - Skipped accounts: $skipped_count"
            ;;
        modify)
            info "  - Successfully modified roles in: $success_count accounts"
            info "  - User not found in: $not_found_count accounts"
            info "  - Failed operations: $fail_count accounts"
            info "  - Skipped accounts: $skipped_count"
            ;;
        remove)
            info "  - Successfully removed from: $success_count accounts"
            info "  - User not found in: $not_found_count accounts"
            info "  - Failed operations: $fail_count accounts"
            info "  - Skipped accounts: $skipped_count"
            ;;
    esac
fi

# Exit with error if any failures occurred
[ $fail_count -gt 0 ] && exit 1
exit 0
