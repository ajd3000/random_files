#!/usr/bin/env python3

import requests
import csv
from datetime import datetime
import argparse
import os
import sys
import time

def verify_token(cf_api_token, verbose=False):
    headers = {
        "Authorization": f"Bearer {cf_api_token}",
        "Content-Type": "application/json"
    }
    try:
        url = "https://api.cloudflare.com/client/v4/user/tokens/verify"
        response = requests.get(url, headers=headers)
        result = response.json()
        if result['success']:
            if verbose:
                print("API Token is valid")
                print("Token status:", result['result']['status'])
            return True
        else:
            print("API Token validation failed")
            if 'errors' in result:
                print("Errors:", result['errors'])
            return False
    except requests.exceptions.RequestException as e:
        print(f"Error verifying token: {e}")
        return False

def test_permissions(cf_api_token, verbose=False):
    headers = {
        "Authorization": f"Bearer {cf_api_token}",
        "Content-Type": "application/json"
    }
    try:
        url = "https://api.cloudflare.com/client/v4/accounts?page=1&per_page=1"
        response = requests.get(url, headers=headers)
        result = response.json()
        if not result['success']:
            print("Warning: Cannot access accounts. Please check token permissions.")
            return False

        if verbose:
            print("Successfully verified account access permissions")
        return True
    except requests.exceptions.RequestException as e:
        print(f"Error testing permissions: {e}")
        return False

def get_cloudflare_accounts(cf_api_token, verbose=False):
    headers = {
        "Authorization": f"Bearer {cf_api_token}",
        "Content-Type": "application/json"
    }
    accounts = []
    page = 1
    per_page = 100  # Maximum allowed by Cloudflare API

    try:
        while True:
            url = f"https://api.cloudflare.com/client/v4/accounts?page={page}&per_page={per_page}"
            response = requests.get(url, headers=headers)
            response.raise_for_status()
            result = response.json()

            if not result['success']:
                print(f"API Error: {result['errors']}")
                return []

            page_accounts = result['result']
            accounts.extend(page_accounts)

            if verbose:
                print(f"Retrieved {len(page_accounts)} accounts from page {page}")

            if len(page_accounts) < per_page:
                break

            page += 1
            time.sleep(0.5)  # Add a small delay to avoid rate limiting

        if verbose:
            print(f"Total accounts retrieved: {len(accounts)}")
        return accounts
    except requests.exceptions.RequestException as e:
        print(f"Error fetching accounts: {e}")
        return []

def get_zones_for_account(cf_api_token, account_id, verbose=False):
    headers = {
        "Authorization": f"Bearer {cf_api_token}",
        "Content-Type": "application/json"
    }
    zones = []
    page = 1
    per_page = 50

    try:
        while True:
            url = f"https://api.cloudflare.com/client/v4/zones?account.id={account_id}&page={page}&per_page={per_page}"
            response = requests.get(url, headers=headers)
            response.raise_for_status()
            result = response.json()

            if not result['success']:
                print(f"API Error for account {account_id}: {result['errors']}")
                return []

            page_zones = result['result']

            # Extract plan information for each zone
            for zone in page_zones:
                if 'plan' in zone:
                    # Get the plan name and clean it up
                    plan_name = zone['plan'].get('name', 'Unknown')
                    # Some plans might be returned as "Enterprise Website" or similar
                    if 'enterprise' in plan_name.lower():
                        zone['plan_type'] = 'Enterprise'
                    elif 'business' in plan_name.lower():
                        zone['plan_type'] = 'Business'
                    elif 'pro' in plan_name.lower():
                        zone['plan_type'] = 'Pro'
                    elif 'free' in plan_name.lower():
                        zone['plan_type'] = 'Free'
                    else:
                        zone['plan_type'] = plan_name
                else:
                    zone['plan_type'] = 'Unknown'

            zones.extend(page_zones)

            if verbose:
                print(f"Retrieved {len(page_zones)} zones from page {page} for account {account_id}")

            if len(page_zones) < per_page:
                break

            page += 1
            time.sleep(0.5)

        return zones
    except requests.exceptions.RequestException as e:
        print(f"Error fetching zones for account {account_id}: {e}")
        return []

# Returned when a phase has never had an entry point ruleset deployed.
MISSING_ENTRYPOINT_CODE = 10003

# Well-known Cloudflare managed ruleset IDs -> friendly names
KNOWN_MANAGED_RULESETS = {
    "efb7b8c949ac4650a09736fc376e9aee": "Cloudflare Managed Ruleset",
    "4814384a9e5d4991b9815dcfc25d2f1f": "Cloudflare OWASP Core Ruleset",
}

def get_error_codes(payload):
    return {err.get('code') for err in (payload.get('errors') or [])}

def describe_api_errors(response):
    try:
        payload = response.json()
    except ValueError:
        return response.text.strip()[:200]

    errors = payload.get('errors') or []
    if not errors:
        return f"HTTP {response.status_code}"
    return "; ".join(
        f"{err.get('code', '?')}: {err.get('message', 'unknown error')}" for err in errors
    )

def ruleset_label(rule):
    description = (rule.get('description') or '').strip()
    ruleset_id = (rule.get('action_parameters') or {}).get('id')
    known = KNOWN_MANAGED_RULESETS.get(ruleset_id)
    return description or known or ruleset_id or 'unnamed ruleset'

def fetch_managed_entrypoint(cf_api_token, scope, scope_id, verbose=False):
    """
    Fetch the http_request_firewall_managed entry point for a zone or account.
    Returns (ok, rules, auth_denied).
    ok=False means a hard API failure; ok=True with [] means no entrypoint / nothing deployed.
    auth_denied=True means 401/403 (caller may soft-fail for account scope).
    """
    headers = {
        "Authorization": f"Bearer {cf_api_token}",
        "Content-Type": "application/json"
    }
    url = (
        f"https://api.cloudflare.com/client/v4/{scope}/{scope_id}"
        "/rulesets/phases/http_request_firewall_managed/entrypoint"
    )

    try:
        response = requests.get(url, headers=headers)
        try:
            result = response.json()
        except ValueError:
            print(f"Non-JSON response checking {scope} {scope_id}: HTTP {response.status_code}")
            return False, [], False

        if MISSING_ENTRYPOINT_CODE in get_error_codes(result) or response.status_code == 404:
            if verbose:
                print(f"No managed rules entry point for {scope} {scope_id}")
            return True, [], False

        if response.status_code in (401, 403) or 10000 in get_error_codes(result):
            if verbose:
                print(f"Not authorized to read WAF rulesets for {scope} {scope_id}: {describe_api_errors(response)}")
            return False, [], True

        if not result.get('success'):
            print(f"API Error checking WAF for {scope} {scope_id}: {describe_api_errors(response)}")
            return False, [], False

        return True, (result.get('result') or {}).get('rules') or [], False

    except requests.exceptions.RequestException as e:
        print(f"Error checking WAF status for {scope} {scope_id}: {e}")
        return False, [], False


def account_rule_applies_to_zone(rule, zone_name, plan_type):
    """Best-effort match of account-level execute rule expression to a zone."""
    expr = (rule.get('expression') or 'true').strip()
    expr_l = expr.lower()
    zone_l = zone_name.lower()

    if expr_l == 'true':
        return True

    if f'"{zone_l}"' in expr_l or f"'{zone_l}'" in expr_l:
        return True

    if 'cf.zone.name' not in expr_l:
        if 'cf.zone.plan' in expr_l:
            if plan_type and plan_type.lower() == 'enterprise':
                return '"ent"' in expr_l or 'enterprise' in expr_l
            return False
        return True

    return False


def enabled_execute_labels(rules, source, zone_name=None, plan_type=None):
    labels = []
    for rule in rules:
        if rule.get('action') != 'execute':
            continue
        if rule.get('enabled') is False:
            continue
        if source == 'Account' and zone_name is not None:
            if not account_rule_applies_to_zone(rule, zone_name, plan_type):
                continue
        labels.append(f"{source}: {ruleset_label(rule)}")
    return labels


def check_waf_status(cf_api_token, zone, account_id, account_rules_cache, verbose=False):
    """
    WAF is Enabled if the zone has zone-level managed rulesets OR matching
    account-level (Global) managed rulesets. Dashboard shows Cloudflare managed
    rulesets as (Global) even when deployed at zone scope.
    """
    zone_ok, zone_rules, zone_auth_denied = fetch_managed_entrypoint(
        cf_api_token, 'zones', zone['id'], verbose
    )
    if zone_auth_denied:
        print(f"Not authorized to read zone WAF rulesets for {zone['name']} ({zone['id']})")
        return None, []
    if not zone_ok:
        return None, []

    if account_id not in account_rules_cache:
        acct_ok, acct_rules, acct_auth_denied = fetch_managed_entrypoint(
            cf_api_token, 'accounts', account_id, verbose
        )
        if acct_auth_denied:
            # Soft-fail: many tokens only have Zone WAF Read. Keep scanning zone-level.
            if not account_rules_cache.get('_warned_account_auth'):
                print(
                    "Warning: token cannot read account-level managed rulesets "
                    "(add Account / Account Rulesets: Read). Continuing with zone-level checks only."
                )
                account_rules_cache['_warned_account_auth'] = True
            account_rules_cache[account_id] = (True, [])
        elif not acct_ok:
            account_rules_cache[account_id] = (False, [])
        else:
            account_rules_cache[account_id] = (True, acct_rules)

    acct_ok, acct_rules = account_rules_cache[account_id]
    if not acct_ok:
        zone_labels = enabled_execute_labels(zone_rules, 'Zone')
        if zone_labels:
            return True, zone_labels
        return None, []

    deployed = []
    deployed.extend(enabled_execute_labels(zone_rules, 'Zone'))
    deployed.extend(
        enabled_execute_labels(
            acct_rules,
            'Account',
            zone_name=zone['name'],
            plan_type=zone.get('plan_type'),
        )
    )

    if verbose:
        if deployed:
            print(f"Zone {zone['name']} protected by: {', '.join(deployed)}")
        else:
            print(f"Zone {zone['name']} has no enabled managed rulesets (zone or account)")

    return bool(deployed), deployed

def main():
    parser = argparse.ArgumentParser(description='Check Cloudflare domains WAF status')
    parser.add_argument('--token', help='Cloudflare API token')
    parser.add_argument('--output', help='Output file name (optional)', default=None)
    parser.add_argument('--verbose', '-v', action='store_true', help='Enable verbose output')
    args = parser.parse_args()

    # Counter variables
    total_domains = 0
    waf_enabled = 0
    waf_disabled = 0
    waf_error = 0

    # First check if token is provided as command line argument
    cf_api_token = args.token

    # If not, check environment variable
    if not cf_api_token:
        cf_api_token = os.getenv('CLOUDFLARE_API_TOKEN')

    # If still no token, exit with error
    if not cf_api_token:
        print("Error: No API token provided. Either set CLOUDFLARE_API_TOKEN environment variable or use --token argument")
        sys.exit(1)

    # Verify token is valid
    if not verify_token(cf_api_token, args.verbose):
        print("Token validation failed. Please check your API token and try again")
        sys.exit(1)

    # Test actual permissions
    if not test_permissions(cf_api_token, args.verbose):
        print("Permission test failed. Please ensure your token has the required permissions:")
        print("- Account / Account Settings: Read")
        print("- Account / Account Rulesets: Read  (needed for Global/account WAF)")
        print("- Zone / Zone: Read")
        print("- Zone / Zone WAF: Read")
        sys.exit(1)

    # Set output filename
    if args.output:
        output_file = args.output
    else:
        output_file = f"domains_waf_status_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"

    print(f"Starting WAF check... Results will be saved to {output_file}")

    with open(output_file, 'w', newline='') as csvfile:
        writer = csv.writer(csvfile)
        writer.writerow(['Account Name', 'Account ID', 'Domain', 'Zone ID', 'Plan Type', 'WAF Status', 'Managed Rulesets'])

        # Get all accounts
        accounts = get_cloudflare_accounts(cf_api_token, args.verbose)
        total_accounts = len(accounts)

        if not accounts:
            print("No accounts found or error occurred while fetching accounts.")
            sys.exit(1)

        print(f"Found {total_accounts} accounts to check...")
        account_rules_cache = {}

        for index, account in enumerate(accounts, 1):
            print(f"\nChecking account {index}/{total_accounts}: {account['name']}")

            # Get all zones (domains) for the account
            zones = get_zones_for_account(cf_api_token, account['id'], args.verbose)

            if not zones:
                if args.verbose:
                    print(f"No zones found or error occurred for account: {account['name']}")
                continue

            print(f"Found {len(zones)} domains in account {account['name']}")
            total_domains += len(zones)

            for zone in zones:
                waf_status, deployed = check_waf_status(
                    cf_api_token,
                    zone,
                    account['id'],
                    account_rules_cache,
                    args.verbose,
                )

                if waf_status is None:
                    status = 'Error checking'
                    waf_error += 1
                elif not waf_status:
                    status = 'Disabled'
                    waf_disabled += 1
                else:
                    status = 'Enabled'
                    waf_enabled += 1

                writer.writerow([
                    account['name'],
                    account['id'],
                    zone['name'],
                    zone['id'],
                    zone['plan_type'],
                    status,
                    " | ".join(deployed)
                ])
                if status == 'Enabled':
                    print(f"Domain with WAF: {zone['name']} (Plan: {zone['plan_type']})")
                else:
                    print(f"Domain without WAF: {zone['name']} (Plan: {zone['plan_type']})")

            # Add a small delay between accounts to avoid rate limiting
            time.sleep(1)

    print(f"\nCheck complete! Results have been saved to {output_file}")
    print("\nSummary:")
    print(f"Total Accounts: {total_accounts}")
    print(f"Total Domains: {total_domains}")
    print(f"Domains with WAF Enabled: {waf_enabled}")
    print(f"Domains with WAF Disabled: {waf_disabled}")
    if waf_error > 0:
        print(f"Domains with WAF Check Errors: {waf_error}")
    if total_domains:
        print(f"WAF Coverage: {(waf_enabled/total_domains*100):.2f}%")

if __name__ == "__main__":
    main()
