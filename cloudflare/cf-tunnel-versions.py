#!/usr/bin/env python3
"""Find Cloudflare accounts whose cloudflared connectors are below 2026.10.2.

Read-only. Uses the account list plus the Tunnel connections API
(client_version / arch). The October 2026 emSign advisory says cloudflared
before 2026.10.2 still trusts the weak intermediates. macOS installs that
were not done with Homebrew need 2026.10.3; the API cannot see Homebrew, so
darwin connectors on exactly 2026.10.2 are flagged for a manual check.

Token needs permission to list accounts and to read Cloudflare Tunnels
(Account > Cloudflare Tunnel > Read, or the equivalent Zero Trust tunnel read).
"""

import argparse
import csv
import os
import sys
import time
from datetime import datetime

import requests

API = "https://api.cloudflare.com/client/v4"
MIN_VERSION = (2026, 10, 2)
MACOS_MIN_VERSION = (2026, 10, 3)


def parse_version(value):
    if not value:
        return None
    parts = []
    for piece in str(value).split("."):
        digits = []
        for ch in piece:
            if ch.isdigit():
                digits.append(ch)
            else:
                break
        if not digits:
            break
        parts.append(int("".join(digits)))
    if not parts:
        return None
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])


def assess(version_text, arch):
    version = parse_version(version_text)
    if version is None:
        return "unknown_version"
    arch_text = (arch or "").lower()
    if arch_text.startswith("darwin") and version < MACOS_MIN_VERSION:
        if version < MIN_VERSION:
            return "outdated"
        return "macos_review"
    if version < MIN_VERSION:
        return "outdated"
    return "ok"


class Cloudflare:
    def __init__(self, token, delay):
        self.session = requests.Session()
        self.session.headers.update(
            {
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            }
        )
        self.delay = delay

    def get(self, path, params=None):
        url = API + path
        for attempt in range(6):
            response = self.session.get(url, params=params, timeout=60)
            if response.status_code == 429:
                wait = int(response.headers.get("Retry-After", "2"))
                time.sleep(max(wait, 2))
                continue
            if response.status_code in (500, 502, 503, 504) and attempt < 5:
                time.sleep(2 * (attempt + 1))
                continue
            try:
                body = response.json()
            except ValueError:
                response.raise_for_status()
                raise
            time.sleep(self.delay)
            return response.status_code, body
        response.raise_for_status()
        return response.status_code, response.json()

    def paginate(self, path, params=None):
        page = 1
        per_page = 50
        params = dict(params or {})
        while True:
            params["page"] = page
            params["per_page"] = per_page
            status, body = self.get(path, params)
            if status == 403 or not body.get("success"):
                yield status, body, []
                return
            batch = body.get("result") or []
            yield status, body, batch
            info = body.get("result_info") or {}
            total_pages = info.get("total_pages")
            if total_pages is not None:
                if page >= total_pages:
                    break
            elif len(batch) < per_page:
                break
            page += 1


def tunnel_rows(account_name, account_id, tunnel, clients):
    tunnel_name = tunnel.get("name") or ""
    tunnel_id = tunnel.get("id") or ""
    tunnel_status = tunnel.get("status") or ""
    rows = []
    seen = set()
    for client in clients:
        arch = client.get("arch") or ""
        version = client.get("version") or ""
        for conn in client.get("conns") or []:
            client_version = conn.get("client_version") or version
            key = (
                conn.get("client_id") or client.get("id") or "",
                client_version,
                conn.get("origin_ip") or "",
            )
            if key in seen:
                continue
            seen.add(key)
            rows.append(
                {
                    "account_name": account_name,
                    "account_id": account_id,
                    "tunnel_name": tunnel_name,
                    "tunnel_id": tunnel_id,
                    "tunnel_status": tunnel_status,
                    "client_id": conn.get("client_id") or client.get("id") or "",
                    "client_version": client_version,
                    "arch": arch,
                    "origin_ip": conn.get("origin_ip") or "",
                    "colo": conn.get("colo_name") or "",
                    "opened_at": conn.get("opened_at") or "",
                    "assessment": assess(client_version, arch),
                }
            )
    if rows:
        return rows
    return [
        {
            "account_name": account_name,
            "account_id": account_id,
            "tunnel_name": tunnel_name,
            "tunnel_id": tunnel_id,
            "tunnel_status": tunnel_status,
            "client_id": "",
            "client_version": "",
            "arch": "",
            "origin_ip": "",
            "colo": "",
            "opened_at": "",
            "assessment": "no_active_connector",
        }
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "-t",
        "--token",
        default=os.environ.get("CF_API_TOKEN") or os.environ.get("CLOUDFLARE_API_TOKEN"),
        help="Cloudflare API token (or CF_API_TOKEN)",
    )
    parser.add_argument(
        "-o",
        "--output",
        help="CSV path. Default: cloudflared-versions-<timestamp>.csv in the working directory",
    )
    parser.add_argument(
        "--delay",
        type=float,
        default=0.15,
        help="Seconds to sleep between API calls (default 0.15)",
    )
    parser.add_argument(
        "--account-id",
        action="append",
        default=[],
        help="Limit to one account id. Repeat for several. Default: every account the token can list.",
    )
    args = parser.parse_args()
    if not args.token:
        print("Set CF_API_TOKEN or pass --token.", file=sys.stderr)
        return 2

    cf = Cloudflare(args.token, args.delay)
    status, verify = cf.get("/user/tokens/verify")
    if status != 200 or not verify.get("success"):
        print(f"Token verify failed: {verify.get('errors')}", file=sys.stderr)
        return 2

    if args.account_id:
        accounts = [{"id": account_id, "name": account_id} for account_id in args.account_id]
    else:
        accounts = []
        for status, body, batch in cf.paginate("/accounts"):
            if not body.get("success"):
                print(f"Cannot list accounts: {body.get('errors')}", file=sys.stderr)
                return 2
            accounts.extend(batch)

    output = args.output or (
        "cloudflared-versions-" + datetime.now().strftime("%Y%m%d-%H%M%S") + ".csv"
    )
    fields = [
        "account_name",
        "account_id",
        "tunnel_name",
        "tunnel_id",
        "tunnel_status",
        "client_id",
        "client_version",
        "arch",
        "origin_ip",
        "colo",
        "opened_at",
        "assessment",
    ]
    impacted = {}
    accounts_with_tunnels = {}
    tunnels_seen = 0
    denied = 0
    rows_written = 0

    with open(output, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for index, account in enumerate(accounts, start=1):
            account_id = account.get("id")
            account_name = account.get("name") or account_id
            print(f"[{index}/{len(accounts)}] {account_name}", flush=True)
            account_denied = False
            for status, body, tunnels in cf.paginate(
                f"/accounts/{account_id}/cfd_tunnel",
                {"is_deleted": "false"},
            ):
                if status in (401, 403) or not body.get("success"):
                    errors = body.get("errors") or []
                    code = errors[0].get("code") if errors else status
                    if code in (10000, 9109, 1003) or status in (401, 403):
                        account_denied = True
                        denied += 1
                        print(f"  no tunnel permission ({code})", flush=True)
                    else:
                        print(f"  tunnel list error: {errors}", flush=True)
                    break
                for tunnel in tunnels:
                    tunnels_seen += 1
                    accounts_with_tunnels.setdefault(account_id, account_name)
                    clients = []
                    conn_status, conn_body = cf.get(
                        f"/accounts/{account_id}/cfd_tunnel/{tunnel.get('id')}/connections"
                    )
                    if conn_body.get("success"):
                        result = conn_body.get("result") or []
                        if isinstance(result, dict):
                            clients = [result]
                        else:
                            clients = result
                    for row in tunnel_rows(account_name, account_id, tunnel, clients):
                        writer.writerow(row)
                        rows_written += 1
                        if row["assessment"] in ("outdated", "macos_review", "unknown_version"):
                            impacted.setdefault(account_id, account_name)
                if account_denied:
                    break

    print()
    print(f"Accounts scanned: {len(accounts)}")
    print(f"Accounts the token cannot read tunnels for: {denied}")
    print(f"Accounts with at least one tunnel: {len(accounts_with_tunnels)}")
    print(f"Tunnels found: {tunnels_seen}")
    print(f"Connector rows written: {rows_written}")
    print(f"CSV: {output}")
    print()
    print("Accounts that match the email (they have a Cloudflare Tunnel):")
    if not accounts_with_tunnels:
        print("  none")
    for account_id, account_name in sorted(
        accounts_with_tunnels.items(), key=lambda item: item[1].lower()
    ):
        print(f"  {account_name}  {account_id}")
    print()
    if not impacted:
        print("No outdated, macOS-review, or unknown-version connectors found.")
        print("Accounts with only 'no_active_connector' or 'ok' rows are in the CSV.")
        return 0
    print("Accounts with a connector below 2026.10.2, a darwin 2026.10.2, or an unparsed version:")
    for account_id, account_name in sorted(impacted.items(), key=lambda item: item[1].lower()):
        print(f"  {account_name}  {account_id}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
