#!/bin/bash
#
# List Elastic IPs and the resource they are associated with (if any).
# Useful for finding unused EIPs that can be released for cost savings.
#
# Usage:
#   ./aws-eip-availability-check.sh --profile APX-Aptexx-RO --region us-west-2
#
# Resource ID meanings:
#   AVAILABLE              - EIP is not associated; candidate for release
#   DETACHED ENI (...)     - EIP is on an unattached ENI; investigate before release
#   i-... / nat-... / ELB  - EIP is actively associated with a resource
#

set -euo pipefail

PROFILE=""
REGION=""

usage() {
    cat <<EOF
Usage: $0 --profile <profile_name> --region <region_name>

Options:
  --profile   AWS CLI profile name
  --region    AWS region (e.g. us-west-2)
  -h, --help  Show this help

Example:
  $0 --profile APX-Aptexx-RO --region us-west-2
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --profile)
            PROFILE="${2:-}"
            shift 2
            ;;
        --region)
            REGION="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown parameter: $1" >&2
            usage
            ;;
    esac
done

if [[ -z "$PROFILE" || -z "$REGION" ]]; then
    usage
fi

for cmd in aws jq column; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: '$cmd' is required but not installed." >&2
        exit 1
    fi
done

AWS=(aws --profile "$PROFILE" --region "$REGION")

# Verify credentials early with a clear error
if ! "${AWS[@]}" sts get-caller-identity >/dev/null 2>&1; then
    echo "Error: unable to authenticate with profile '$PROFILE'." >&2
    echo "Try: aws sso login --sso-session inhabit-sso" >&2
    exit 1
fi

echo "Profile: $PROFILE  Region: $REGION" >&2
echo "Scanning Elastic IPs..." >&2

addresses=$("${AWS[@]}" ec2 describe-addresses --output json)

if [[ "$(jq '.Addresses | length' <<<"$addresses")" -eq 0 ]]; then
    echo "No Elastic IPs found in $REGION for profile $PROFILE."
    exit 0
fi

{
    printf 'Name\tIP\tResource ID\tNetwork Interface ID\tAssociation ID\n'

    while IFS= read -r addr; do
        name=$(jq -r '(.Tags // [] | map(select(.Key=="Name")) | .[0].Value) // "-"' <<<"$addr")
        ip=$(jq -r '.PublicIp // "-"' <<<"$addr")
        eni=$(jq -r '.NetworkInterfaceId // empty' <<<"$addr")
        assoc=$(jq -r '.AssociationId // empty' <<<"$addr")
        instance=$(jq -r '.InstanceId // empty' <<<"$addr")
        allocation=$(jq -r '.AllocationId // empty' <<<"$addr")

        eni_out="${eni:--}"
        assoc_out="${assoc:--}"

        if [[ -z "$assoc" ]]; then
            resource="AVAILABLE"
            eni_out="-"
            assoc_out="-"

        elif [[ -n "$instance" ]]; then
            resource="$instance"

        elif [[ -n "$eni" ]]; then
            ni=$("${AWS[@]}" ec2 describe-network-interfaces \
                --network-interface-ids "$eni" \
                --output json)

            eni_instance=$(jq -r \
                '.NetworkInterfaces[0].Attachment.InstanceId // empty' <<<"$ni")
            eni_status=$(jq -r \
                '.NetworkInterfaces[0].Status // empty' <<<"$ni")
            eni_name=$(jq -r \
                '(.NetworkInterfaces[0].TagSet // [] |
                 map(select(.Key=="Name")) | .[0].Value) // empty' <<<"$ni")
            description=$(jq -r \
                '.NetworkInterfaces[0].Description // empty' <<<"$ni")

            nat_id=$("${AWS[@]}" ec2 describe-nat-gateways \
                --filter "Name=nat-gateway-address.allocation-id,Values=$allocation" \
                --query 'NatGateways[0].NatGatewayId' \
                --output text 2>/dev/null || true)

            [[ "$nat_id" == "None" || "$nat_id" == "null" ]] && nat_id=""

            if [[ -n "$eni_instance" ]]; then
                resource="$eni_instance"
            elif [[ -n "$nat_id" ]]; then
                resource="$nat_id"
            elif [[ "$eni_status" == "available" ]]; then
                label="${eni_name:-$description}"
                if [[ -n "$label" ]]; then
                    resource="DETACHED ENI ($label)"
                else
                    resource="DETACHED ENI"
                fi
            elif [[ "$description" =~ (nat|i|vgw|vpce)-[a-zA-Z0-9-]+ ]]; then
                resource="${BASH_REMATCH[0]}"
            elif [[ -n "$description" ]]; then
                resource="$description"
            else
                resource="ASSOCIATED ENI"
            fi
        else
            resource="ASSOCIATED (unknown resource)"
            eni_out="-"
        fi

        printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$ip" "$resource" "$eni_out" "$assoc_out"
    done < <(jq -c '.Addresses[]' <<<"$addresses")
} | column -t -s $'\t'
