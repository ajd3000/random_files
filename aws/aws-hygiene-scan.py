#!/usr/bin/env python3
"""
Multi-account AWS hygiene scanner (ReadOnly / *-RO profiles only).

Checks (script "services"):
  --snapshots   EBS snapshots older than --snapshot-age (default 30d)
  --volumes     Orphaned/available EBS volumes (not attached)
  --eip         Elastic IPs not associated with a resource
  --stopped     EC2 instances stopped longer than --stopped-age (default 180d)

Account selection:
  --allaccounts     All AWS CLI profiles ending in -RO
  --account NAME    One account (IIQ-Corp or IIQ-Corp-RO both resolve to *-RO)

SSO: uses sso-session inhabit-sso; prompts once via `aws sso login` if needed.
"""

from __future__ import annotations

import argparse
import csv
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from typing import Dict, List, Optional, Sequence, Tuple

try:
    import boto3
    from botocore.exceptions import BotoCoreError, ClientError
except ImportError:  # pragma: no cover - help still works without boto3
    boto3 = None  # type: ignore[assignment]
    BotoCoreError = ClientError = Exception  # type: ignore[misc,assignment]

SSO_SESSION = "inhabit-sso"
DEFAULT_REGIONS = ["us-east-1", "us-east-2", "us-west-1", "us-west-2"]
DEFAULT_SNAPSHOT_AGE_DAYS = 30
DEFAULT_STOPPED_AGE_DAYS = 180

SERVICES = ("snapshots", "volumes", "eip", "stopped")

CSV_HEADERS = [
    "Check",
    "AccountId",
    "AccountName",
    "Profile",
    "Region",
    "ResourceId",
    "ResourceName",
    "Detail",
    "AgeDays",
    "CreatedOrStoppedAt",
    "SizeGiB",
    "Extra",
]

STOP_REASON_RE = re.compile(
    r"\((\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\s+GMT\)"
)


def eprint(*args: object) -> None:
    print(*args, file=sys.stderr)


def parse_duration_days(value: str, flag: str) -> int:
    text = value.strip().lower()
    if text.endswith("d"):
        text = text[:-1]
    if not text.isdigit() or int(text) < 1:
        raise argparse.ArgumentTypeError(
            f"{flag} expects a positive day count like 30 or 30d (got {value!r})"
        )
    return int(text)


def tag_name(tags: Optional[Sequence[dict]]) -> str:
    for tag in tags or []:
        if tag.get("Key") == "Name":
            return (tag.get("Value") or "").strip() or "N/A"
    return "N/A"


def age_days(when: datetime, now: datetime) -> int:
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    return max(0, int((now - when).total_seconds() // 86400))


def iso_z(when: Optional[datetime]) -> str:
    if when is None:
        return "N/A"
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    return when.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _require_boto3() -> None:
    if boto3 is None:
        raise SystemExit(
            "boto3 is required. Install with: pip install boto3 "
            "(run this script from the same Python/WSL env as your AWS CLI)."
        )


def list_ro_profiles() -> List[str]:
    _require_boto3()
    session = boto3.Session()
    profiles = sorted(session.available_profiles)
    return [p for p in profiles if p.endswith("-RO")]


def resolve_ro_profile(account: str) -> str:
    name = account.strip()
    if not name:
        raise ValueError("empty --account value")
    if name.endswith("-RO"):
        candidate = name
    else:
        candidate = f"{name}-RO"
    available = set(list_ro_profiles())
    if candidate not in available:
        hint = ""
        partial = [p for p in available if name.lower() in p.lower()]
        if partial:
            hint = f" Similar RO profiles: {', '.join(partial[:8])}"
        raise ValueError(
            f"No ReadOnly profile '{candidate}' in ~/.aws/config.{hint}"
        )
    return candidate


def ensure_sso(profile: str) -> None:
    """Validate credentials for profile; run SSO login once if the session is cold."""
    _require_boto3()
    try:
        boto3.Session(profile_name=profile).client("sts").get_caller_identity()
        return
    except Exception as exc:
        # SSO token/expiry surfaces as several botocore exception types.
        eprint(f"SSO/session not valid for {profile}: {exc}")
        eprint(f"Running: aws sso login --sso-session {SSO_SESSION}")
        result = subprocess.run(
            ["aws", "sso", "login", "--sso-session", SSO_SESSION],
            check=False,
        )
        if result.returncode != 0:
            raise SystemExit(
                f"aws sso login failed (exit {result.returncode}). "
                "Complete browser login and retry."
            )
    try:
        boto3.Session(profile_name=profile).client("sts").get_caller_identity()
    except Exception as exc:
        raise SystemExit(f"Still cannot authenticate profile '{profile}': {exc}")


def account_meta(session, profile: str) -> Tuple[str, str]:
    ident = session.client("sts").get_caller_identity()
    account_id = ident["Account"]
    name = profile[:-3] if profile.endswith("-RO") else profile
    try:
        aliases = session.client("iam").list_account_aliases().get("AccountAliases") or []
        if aliases:
            name = aliases[0]
    except (ClientError, BotoCoreError):
        pass
    return account_id, name


def row(
    check: str,
    account_id: str,
    account_name: str,
    profile: str,
    region: str,
    resource_id: str,
    resource_name: str,
    detail: str,
    age: Optional[int] = None,
    when: Optional[datetime] = None,
    size_gib: Optional[float] = None,
    extra: str = "",
) -> Dict[str, str]:
    return {
        "Check": check,
        "AccountId": account_id,
        "AccountName": account_name,
        "Profile": profile,
        "Region": region,
        "ResourceId": resource_id,
        "ResourceName": resource_name,
        "Detail": detail,
        "AgeDays": "" if age is None else str(age),
        "CreatedOrStoppedAt": iso_z(when),
        "SizeGiB": "" if size_gib is None else str(size_gib),
        "Extra": extra or "",
    }


def parse_stopped_at(instance: dict) -> Optional[datetime]:
    reason = instance.get("StateTransitionReason") or ""
    match = STOP_REASON_RE.search(reason)
    if match:
        try:
            return datetime.strptime(match.group(1), "%Y-%m-%d %H:%M:%S").replace(
                tzinfo=timezone.utc
            )
        except ValueError:
            pass
    # Fallback: LaunchTime (underestimates stop age if relaunched long ago then stopped)
    launch = instance.get("LaunchTime")
    if isinstance(launch, datetime):
        return launch if launch.tzinfo else launch.replace(tzinfo=timezone.utc)
    return None


def scan_snapshots(
    ec2,
    *,
    account_id: str,
    account_name: str,
    profile: str,
    region: str,
    cutoff: datetime,
    now: datetime,
) -> List[Dict[str, str]]:
    out: List[Dict[str, str]] = []
    paginator = ec2.get_paginator("describe_snapshots")
    for page in paginator.paginate(OwnerIds=["self"]):
        for snap in page.get("Snapshots", []):
            start = snap.get("StartTime")
            if not isinstance(start, datetime):
                continue
            if start.tzinfo is None:
                start = start.replace(tzinfo=timezone.utc)
            if start >= cutoff:
                continue
            out.append(
                row(
                    "snapshot",
                    account_id,
                    account_name,
                    profile,
                    region,
                    snap["SnapshotId"],
                    tag_name(snap.get("Tags")),
                    snap.get("Description") or "N/A",
                    age=age_days(start, now),
                    when=start,
                    size_gib=float(snap.get("VolumeSize") or 0),
                    extra=f"volume={snap.get('VolumeId') or 'N/A'};state={snap.get('State') or 'N/A'}",
                )
            )
    return out


def scan_volumes(
    ec2,
    *,
    account_id: str,
    account_name: str,
    profile: str,
    region: str,
    now: datetime,
) -> List[Dict[str, str]]:
    out: List[Dict[str, str]] = []
    paginator = ec2.get_paginator("describe_volumes")
    for page in paginator.paginate(
        Filters=[{"Name": "status", "Values": ["available"]}]
    ):
        for vol in page.get("Volumes", []):
            created = vol.get("CreateTime")
            if isinstance(created, datetime) and created.tzinfo is None:
                created = created.replace(tzinfo=timezone.utc)
            out.append(
                row(
                    "volume",
                    account_id,
                    account_name,
                    profile,
                    region,
                    vol["VolumeId"],
                    tag_name(vol.get("Tags")),
                    f"available/{vol.get('VolumeType') or 'N/A'}",
                    age=age_days(created, now) if isinstance(created, datetime) else None,
                    when=created if isinstance(created, datetime) else None,
                    size_gib=float(vol.get("Size") or 0),
                    extra=f"az={vol.get('AvailabilityZone') or 'N/A'}",
                )
            )
    return out


def scan_eips(
    ec2,
    *,
    account_id: str,
    account_name: str,
    profile: str,
    region: str,
) -> List[Dict[str, str]]:
    out: List[Dict[str, str]] = []
    addresses = ec2.describe_addresses().get("Addresses", [])
    for addr in addresses:
        if addr.get("AssociationId"):
            continue
        public_ip = addr.get("PublicIp") or "N/A"
        alloc = addr.get("AllocationId") or public_ip
        out.append(
            row(
                "eip",
                account_id,
                account_name,
                profile,
                region,
                alloc,
                tag_name(addr.get("Tags")),
                "unassociated",
                extra=f"public_ip={public_ip};domain={addr.get('Domain') or 'N/A'}",
            )
        )
    return out


def scan_stopped(
    ec2,
    *,
    account_id: str,
    account_name: str,
    profile: str,
    region: str,
    cutoff: datetime,
    now: datetime,
) -> List[Dict[str, str]]:
    out: List[Dict[str, str]] = []
    paginator = ec2.get_paginator("describe_instances")
    for page in paginator.paginate(
        Filters=[{"Name": "instance-state-name", "Values": ["stopped"]}]
    ):
        for reservation in page.get("Reservations", []):
            for inst in reservation.get("Instances", []):
                stopped_at = parse_stopped_at(inst)
                if stopped_at is None or stopped_at >= cutoff:
                    continue
                reason = (inst.get("StateTransitionReason") or "").strip() or "N/A"
                out.append(
                    row(
                        "stopped",
                        account_id,
                        account_name,
                        profile,
                        region,
                        inst["InstanceId"],
                        tag_name(inst.get("Tags")),
                        reason,
                        age=age_days(stopped_at, now),
                        when=stopped_at,
                        extra=(
                            f"type={inst.get('InstanceType') or 'N/A'};"
                            f"az={inst.get('Placement', {}).get('AvailabilityZone') or 'N/A'}"
                        ),
                    )
                )
    return out


def scan_profile(
    profile: str,
    regions: Sequence[str],
    services: Sequence[str],
    snapshot_cutoff: datetime,
    stopped_cutoff: datetime,
    now: datetime,
) -> List[Dict[str, str]]:
    session = boto3.Session(profile_name=profile)
    try:
        account_id, account_name = account_meta(session, profile)
    except Exception as exc:
        eprint(f"[{profile}] skip account (auth/sts): {exc}")
        return []

    eprint(f"[{profile}] {account_name} ({account_id})")
    findings: List[Dict[str, str]] = []

    for region in regions:
        ec2 = session.client("ec2", region_name=region)
        eprint(f"  [{region}] scanning: {', '.join(services)}")
        try:
            if "snapshots" in services:
                findings.extend(
                    scan_snapshots(
                        ec2,
                        account_id=account_id,
                        account_name=account_name,
                        profile=profile,
                        region=region,
                        cutoff=snapshot_cutoff,
                        now=now,
                    )
                )
            if "volumes" in services:
                findings.extend(
                    scan_volumes(
                        ec2,
                        account_id=account_id,
                        account_name=account_name,
                        profile=profile,
                        region=region,
                        now=now,
                    )
                )
            if "eip" in services:
                findings.extend(
                    scan_eips(
                        ec2,
                        account_id=account_id,
                        account_name=account_name,
                        profile=profile,
                        region=region,
                    )
                )
            if "stopped" in services:
                findings.extend(
                    scan_stopped(
                        ec2,
                        account_id=account_id,
                        account_name=account_name,
                        profile=profile,
                        region=region,
                        cutoff=stopped_cutoff,
                        now=now,
                    )
                )
        except (ClientError, BotoCoreError) as exc:
            eprint(f"  [{region}] skip/error: {exc}")

    return findings


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="aws-hygiene-scan.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=(
            "Scan AWS accounts via ReadOnly (*-RO) profiles for cost/hygiene findings."
        ),
        epilog="""
Required (pick one from each group):
  Accounts:  --allaccounts | --account NAME
  Services:  --allservices | one or more of --snapshots --volumes --eip --stopped

Examples:
  %(prog)s --allaccounts --allservices
  %(prog)s --account IIQ-Corp --snapshots --eip
  %(prog)s --account IIQ-Corp-RO --stopped --region eu-west-1
  %(prog)s --allaccounts --volumes --stopped --snapshot-age 30d --stopped-age 180d
  %(prog)s --allaccounts --allservices -o hygiene-report.csv

Notes:
  - Only profiles ending in -RO are used.
  - Default regions: us-east-1 us-east-2 us-west-1 us-west-2
  - --region replaces the US default (repeatable / space-separated).
  - First run may open a browser for: aws sso login --sso-session inhabit-sso
""".rstrip(),
    )

    accounts = parser.add_argument_group("account selection (required)")
    acct_mutex = accounts.add_mutually_exclusive_group(required=False)
    acct_mutex.add_argument(
        "--allaccounts",
        action="store_true",
        help="Scan every *-RO profile in ~/.aws/config",
    )
    acct_mutex.add_argument(
        "--account",
        metavar="NAME",
        help="Single account short name or RO profile (e.g. IIQ-Corp or IIQ-Corp-RO)",
    )

    services = parser.add_argument_group("service selection (required)")
    services.add_argument(
        "--allservices",
        action="store_true",
        help="Run all script checks: snapshots, volumes, eip, stopped",
    )
    services.add_argument(
        "--snapshots",
        action="store_true",
        help=f"EBS snapshots older than --snapshot-age (default {DEFAULT_SNAPSHOT_AGE_DAYS}d)",
    )
    services.add_argument(
        "--volumes",
        action="store_true",
        help="Orphaned EBS volumes (state=available)",
    )
    services.add_argument(
        "--eip",
        action="store_true",
        help="Elastic IPs with no association",
    )
    services.add_argument(
        "--stopped",
        action="store_true",
        help=f"EC2 instances stopped longer than --stopped-age (default {DEFAULT_STOPPED_AGE_DAYS}d)",
    )

    parser.add_argument(
        "--region",
        dest="regions",
        action="append",
        nargs="+",
        metavar="REGION",
        help=(
            "Region(s) to scan instead of the four US defaults. "
            "Repeatable, e.g. --region eu-west-1 --region ap-southeast-2"
        ),
    )
    parser.add_argument(
        "--snapshot-age",
        default=f"{DEFAULT_SNAPSHOT_AGE_DAYS}d",
        type=lambda v: parse_duration_days(v, "--snapshot-age"),
        metavar="DAYS",
        help=f"Snapshot age threshold (default: {DEFAULT_SNAPSHOT_AGE_DAYS}d)",
    )
    parser.add_argument(
        "--stopped-age",
        default=f"{DEFAULT_STOPPED_AGE_DAYS}d",
        type=lambda v: parse_duration_days(v, "--stopped-age"),
        metavar="DAYS",
        help=f"Stopped-instance age threshold (default: {DEFAULT_STOPPED_AGE_DAYS}d)",
    )
    parser.add_argument(
        "-o",
        "--output",
        metavar="FILE",
        help="CSV output path (default: hygiene-YYYYMMDDTHHMMSSZ.csv)",
    )
    return parser


def flatten_regions(raw: Optional[List[List[str]]]) -> List[str]:
    if not raw:
        return list(DEFAULT_REGIONS)
    out: List[str] = []
    for group in raw:
        for item in group:
            for part in item.split(","):
                region = part.strip()
                if region and region not in out:
                    out.append(region)
    return out


def selected_services(args: argparse.Namespace) -> List[str]:
    if args.allservices:
        return list(SERVICES)
    chosen = [s for s in SERVICES if getattr(args, s)]
    return chosen


def validate_required(args: argparse.Namespace, parser: argparse.ArgumentParser) -> None:
    errors: List[str] = []
    if not args.allaccounts and not args.account:
        errors.append("choose --allaccounts or --account NAME")
    if args.allaccounts and args.account:
        errors.append("use only one of --allaccounts / --account")

    individual = any(getattr(args, s) for s in SERVICES)
    if not args.allservices and not individual:
        errors.append(
            "choose --allservices or one/more of --snapshots --volumes --eip --stopped"
        )
    if args.allservices and individual:
        errors.append("use --allservices alone, or individual service flags (not both)")

    if errors:
        parser.print_help()
        eprint("\nError:")
        for err in errors:
            eprint(f"  - {err}")
        raise SystemExit(2)


def main(argv: Optional[Sequence[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    parser = build_parser()
    if not argv:
        parser.print_help()
        return 0

    args = parser.parse_args(argv)
    validate_required(args, parser)

    services = selected_services(args)
    regions = flatten_regions(args.regions)

    try:
        if args.allaccounts:
            profiles = list_ro_profiles()
            if not profiles:
                eprint("No *-RO profiles found in AWS config.")
                return 1
        else:
            profiles = [resolve_ro_profile(args.account)]
    except ValueError as exc:
        eprint(f"Error: {exc}")
        return 2

    eprint(f"Profiles ({len(profiles)}): {', '.join(profiles)}")
    eprint(f"Services: {', '.join(services)}")
    eprint(f"Regions: {', '.join(regions)}")
    eprint(
        f"Thresholds: snapshots>{args.snapshot_age}d  stopped>{args.stopped_age}d"
    )

    ensure_sso(profiles[0])

    now = datetime.now(timezone.utc)
    snapshot_cutoff = now - timedelta(days=args.snapshot_age)
    stopped_cutoff = now - timedelta(days=args.stopped_age)

    all_rows: List[Dict[str, str]] = []
    for profile in profiles:
        all_rows.extend(
            scan_profile(
                profile,
                regions,
                services,
                snapshot_cutoff,
                stopped_cutoff,
                now,
            )
        )

    outfile = args.output or (
        f"hygiene-{now.strftime('%Y%m%dT%H%M%SZ')}.csv"
    )
    with open(outfile, "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=CSV_HEADERS)
        writer.writeheader()
        writer.writerows(all_rows)

    by_check: Dict[str, int] = {}
    for r in all_rows:
        by_check[r["Check"]] = by_check.get(r["Check"], 0) + 1
    summary = ", ".join(f"{k}={v}" for k, v in sorted(by_check.items())) or "none"
    eprint(f"Wrote {len(all_rows)} finding(s) to {outfile} ({summary})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
