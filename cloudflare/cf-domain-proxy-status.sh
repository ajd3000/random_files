#!/usr/bin/env bash
#
# Export Cloudflare DNS records for a zone to CSV (Name, Type, Value, Proxy Status + manual columns).
#
# Cloudflare API usage is read-only: GET /accounts (paginated, when needed), GET /zones (lookup),
# GET /zones/{id}/dns_records (list). Unfiltered zone listing fails when the token spans >500 accounts;
# this script uses per-account zone queries. The only output is a local CSV file.
#
set -euo pipefail

CF_API="https://api.cloudflare.com/client/v4"

usage() {
    cat << 'EOF'
Usage: domain-proxy-status.sh --domain <ZONE_NAME> -t <CF-API-TOKEN> [--account-id <ID>]

Export all DNS records for a Cloudflare zone to a CSV file. The zone is resolved by
name (e.g. payyourrent.com). Zone lookup uses account.id (required by Cloudflare when
your API token can access more than 500 accounts).

Required:
  --domain <name>   DNS zone name exactly as in Cloudflare (apex domain)
  -t, --token TOKEN Cloudflare API token (read-only: Account read, Zone read, DNS read)

Optional:
  --account-id ID   Cloudflare account ID that owns the zone (skips searching all accounts)
  -h, --help        Show this help

Output:
  domain-proxy-status_<YYYYMMDD-HHMMSS>.csv in the current working directory.

CSV columns (filled by API): Name, Record Type, Value, Proxy Status (True/False)
Columns left empty for manual review: Keep?, Can we turn on Proxy?, Known Protocols, Info

Examples:
  ./domain-proxy-status.sh --domain payyourrent.com -t "$CF_API_TOKEN"
  ./domain-proxy-status.sh --domain example.com --token "$CF_API_TOKEN" --account-id abc123...

Dependencies: curl, jq
EOF
}

error() {
    echo "Error: $*" >&2
}

warn() {
    echo "Warning: $*" >&2
}

require_cmds() {
    local missing=()
    for c in curl jq; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if ((${#missing[@]})); then
        error "Missing required commands: ${missing[*]}"
        exit 1
    fi
}

check_api_json() {
    local response=$1
    local ctx=$2
    if ! echo "$response" | jq -e . >/dev/null 2>&1; then
        error "$ctx: invalid JSON"
        echo "$response" >&2
        return 1
    fi
    if ! echo "$response" | jq -e '.success == true' >/dev/null; then
        local msg
        msg=$(echo "$response" | jq -r '[.errors[]?.message] | join("; ")')
        error "$ctx: ${msg:-Unknown API error}"
        return 1
    fi
    return 0
}

# Paginated GET /accounts (same pattern as multi-account tooling; avoids missing accounts past page 1).
fetch_all_accounts() {
    local token=$1
    local page=1
    local per_page=100
    local combined='[]'

    while true; do
        local resp
        resp=$(curl -s -G "${CF_API}/accounts" \
            --data-urlencode "page=${page}" \
            --data-urlencode "per_page=${per_page}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json")

        if ! check_api_json "$resp" "List accounts (page ${page})"; then
            return 1
        fi

        local chunk
        chunk=$(echo "$resp" | jq -c '.result')
        combined=$(echo "$combined $chunk" | jq -s 'add')

        local total_pages
        total_pages=$(echo "$resp" | jq -r '.result_info.total_pages // 1')
        local cur_page
        cur_page=$(echo "$resp" | jq -r '.result_info.page // 1')

        if [[ "$cur_page" -ge "$total_pages" ]]; then
            break
        fi
        page=$((page + 1))
    done

    echo "$combined"
}

# GET /zones with name + account.id (required when token spans many accounts).
zones_for_account_name() {
    local domain=$1
    local token=$2
    local account_id=$3
    local resp
    resp=$(curl -s -G "${CF_API}/zones" \
        --data-urlencode "name=${domain}" \
        --data-urlencode "account.id=${account_id}" \
        --data-urlencode "page=1" \
        --data-urlencode "per_page=50" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json")
    echo "$resp"
}

extract_matching_zone_id() {
    local domain=$1
    local resp=$2
    local count
    count=$(echo "$resp" | jq -r '.result | length')
    if [[ "$count" -eq 0 ]]; then
        return 1
    fi
    local zid
    zid=$(echo "$resp" | jq -r --arg n "$domain" '.result[] | select(.name == $n) | .id' | head -1)
    if [[ -z "$zid" || "$zid" == "null" ]]; then
        zid=$(echo "$resp" | jq -r '.result[0].id')
    fi
    echo "$zid"
}

get_zone_id() {
    local domain=$1
    local token=$2
    local account_id_opt=$3

    if [[ -n "${account_id_opt}" ]]; then
        local resp
        resp=$(zones_for_account_name "$domain" "$token" "$account_id_opt")
        if ! check_api_json "$resp" "Zone lookup (account ${account_id_opt})"; then
            return 1
        fi
        if ! extract_matching_zone_id "$domain" "$resp"; then
            error "No zone found for name: ${domain} in account ${account_id_opt}"
            return 1
        fi
        return 0
    fi

    local accounts_json
    accounts_json=$(fetch_all_accounts "$token") || return 1
    local n_accounts
    n_accounts=$(echo "$accounts_json" | jq 'length')
    if [[ "$n_accounts" -eq 0 ]]; then
        error "No accounts returned for this token (need permission to list accounts)."
        return 1
    fi

    echo "Searching for zone '${domain}' across ${n_accounts} account(s) (per-account API filter)..." >&2

    local aid
    local checked=0
    local progress_every=25
    while IFS= read -r aid; do
        [[ -z "$aid" ]] && continue
        checked=$((checked + 1))
        if (( checked == 1 || checked % progress_every == 0 || checked == n_accounts )); then
            printf 'Progress: checked %d / %d accounts...\n' "$checked" "$n_accounts" >&2
        fi
        local resp
        resp=$(zones_for_account_name "$domain" "$token" "$aid")
        if ! echo "$resp" | jq -e . >/dev/null 2>&1; then
            warn "Invalid JSON for account ${aid}, skipping"
            continue
        fi
        if ! echo "$resp" | jq -e '.success == true' >/dev/null 2>&1; then
            local msg
            msg=$(echo "$resp" | jq -r '[.errors[]?.message] | join("; ")')
            warn "Zones lookup failed for account ${aid}: ${msg:-unknown}"
            continue
        fi
        local zid
        zid=$(extract_matching_zone_id "$domain" "$resp") || continue
        printf 'Found zone after checking %d account(s).\n' "$checked" >&2
        echo "$zid"
        return 0
    done < <(echo "$accounts_json" | jq -r '.[].id')

    error "No zone found for name: ${domain} in any account accessible to this token."
    return 1
}

fetch_all_dns_records() {
    local zone_id=$1
    local token=$2
    local page=1
    local per_page=100
    local combined='[]'

    while true; do
        local resp
        resp=$(curl -s -X GET \
            "${CF_API}/zones/${zone_id}/dns_records?page=${page}&per_page=${per_page}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json")

        if ! check_api_json "$resp" "DNS records page ${page}"; then
            return 1
        fi

        local chunk
        chunk=$(echo "$resp" | jq -c '.result')
        combined=$(echo "$combined $chunk" | jq -s 'add')

        local total_pages
        total_pages=$(echo "$resp" | jq -r '.result_info.total_pages // 1')
        local cur_page
        cur_page=$(echo "$resp" | jq -r '.result_info.page // 1')

        if [[ "$cur_page" -ge "$total_pages" ]]; then
            break
        fi
        page=$((page + 1))
    done

    echo "$combined"
}

DOMAIN=""
TOKEN=""
ACCOUNT_ID=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)
            DOMAIN="${2:-}"
            shift 2
            ;;
        -t|--token)
            TOKEN="${2:-}"
            shift 2
            ;;
        --account-id)
            ACCOUNT_ID="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            echo >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "${DOMAIN}" || -z "${TOKEN}" ]]; then
    usage
    exit 1
fi

require_cmds

ZONE_ID=$(get_zone_id "$DOMAIN" "$TOKEN" "$ACCOUNT_ID") || exit 1

RECORDS_JSON=$(fetch_all_dns_records "$ZONE_ID" "$TOKEN") || exit 1

TS=$(date +%Y%m%d-%H%M%S)
OUTFILE="domain-proxy-status_${TS}.csv"

# Header row (manual columns empty in data rows)
{
    printf '%s\n' "Name,Record Type,Value,Proxy Status,Keep?,Can we turn on Proxy?,Known Protocols,Info"
    echo "$RECORDS_JSON" | jq -r '
        .[] |
        [
            .name,
            .type,
            .content,
            (if .proxied then "True" else "False" end),
            "",
            "",
            "",
            ""
        ] | @csv
    '
} > "$OUTFILE"

echo "Wrote ${OUTFILE} ($(echo "$RECORDS_JSON" | jq 'length') records) for zone ${DOMAIN}"
