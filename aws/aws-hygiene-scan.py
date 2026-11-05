#!/usr/bin/env python3
"""
Multi-account AWS hygiene scanner (ReadOnly / *-RO profiles only).

Checks (script "services"):
  --snapshots   EBS snapshots older than --snapshot-age (default 30d)
  --volumes     Orphaned/available EBS volumes (not attached)
  --eip         Elastic IPs not associated with a resource
  --stopped     EC2 instances stopped longer than --stopped-age (default 180d)
  --nat         NAT gateways (flags idle via CloudWatch BytesOutToDestination)
  --elb         Load balancers with no targets or no healthy targets (ALB/NLB/CLB)
  --ami         Self-owned AMIs older than --ami-age (default 90d)
  --logs        CloudWatch log groups with no retention and/or size >= --log-min-gib

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
DEFAULT_REGIONS = ["us-east-1", "us-east-2", "us-west-1", "us-west-2", "eu-west-2", "ca-central-1"]
DEFAULT_SNAPSHOT_AGE_DAYS = 30
DEFAULT_STOPPED_AGE_DAYS = 180
DEFAULT_AMI_AGE_DAYS = 90
DEFAULT_LOG_MIN_GIB = 5.0
DEFAULT_NAT_IDLE_DAYS = 14

SERVICES = (
    "snapshots",
    "volumes",
    "eip",
    "stopped",
    "nat",
    "elb",
    "ami",
    "logs",
)
SERVICE_FLAGS = " ".join(f"--{s}" for s in SERVICES)

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


def nat_bytes_out_sum(cloudwatch, nat_id: str, days: int, now: datetime) -> Optional[float]:
    try:
        resp = cloudwatch.get_metric_statistics(
            Namespace="AWS/NATGateway",
            MetricName="BytesOutToDestination",
            Dimensions=[{"Name": "NatGatewayId", "Value": nat_id}],
            StartTime=now - timedelta(days=days),
            EndTime=now,
            Period=max(days, 1) * 86400,
            Statistics=["Sum"],
        )
    except (ClientError, BotoCoreError):
        return None
    points = resp.get("Datapoints") or []
    if not points:
        return 0.0
    return float(sum(p.get("Sum") or 0.0 for p in points))


def scan_nat(
    ec2,
    cloudwatch,
    *,
    account_id: str,
    account_name: str,
    profile: str,
    region: str,
    now: datetime,
    idle_days: int,
) -> List[Dict[str, str]]:
    out: List[Dict[str, str]] = []
    paginator = ec2.get_paginator("describe_nat_gateways")
    for page in paginator.paginate(
        Filters=[{"Name": "state", "Values": ["available", "pending"]}]
    ):
        for nat in page.get("NatGateways", []):
            created = nat.get("CreateTime")
            if isinstance(created, datetime) and created.tzinfo is None:
                created = created.replace(tzinfo=timezone.utc)
            nat_id = nat["NatGatewayId"]
            bytes_out = nat_bytes_out_sum(cloudwatch, nat_id, idle_days, now)
            if bytes_out is None:
                activity = "metric-unavailable"
            elif bytes_out <= 0:
                activity = f"idle/{idle_days}d"
            else:
                activity = f"active/{idle_days}d"
            # Always report NAT GWs (fixed hourly cost); idle called out in Detail.
            public_ips = []
            for addr in nat.get("NatGatewayAddresses") or []:
                if addr.get("PublicIp"):
                    public_ips.append(addr["PublicIp"])
            out.append(
                row(
                    "nat",
                    account_id,
                    account_name,
                    profile,
                    region,
                    nat_id,
                    tag_name(nat.get("Tags")),
                    activity,
                    age=age_days(created, now) if isinstance(created, datetime) else None,
                    when=created if isinstance(created, datetime) else None,
                    extra=(
                        f"vpc={nat.get('VpcId') or 'N/A'};"
                        f"subnet={nat.get('SubnetId') or 'N/A'};"
                        f"bytes_out_{idle_days}d={bytes_out if bytes_out is not None else 'N/A'};"
                        f"public_ip={','.join(public_ips) or 'N/A'}"
                    ),
                )
            )
    return out


def _elb_v2_target_counts(elbv2, lb_arn: str) -> Tuple[int, int]:
    """Return (registered_targets, healthy_targets) across all target groups."""
    registered = 0
    healthy = 0
    tg_paginator = elbv2.get_paginator("describe_target_groups")
    for page in tg_paginator.paginate(LoadBalancerArn=lb_arn):
        for tg in page.get("TargetGroups", []):
            try:
                health = elbv2.describe_target_health(
                    TargetGroupArn=tg["TargetGroupArn"]
                )
            except (ClientError, BotoCoreError):
                continue
            for th in health.get("TargetHealthDescriptions", []):
                registered += 1
                state = (th.get("TargetHealth") or {}).get("State")
                if state == "healthy":
                    healthy += 1
    return registered, healthy


def scan_elb(
    elbv2,
    elb,
    *,
    account_id: str,
    account_name: str,
    profile: str,
    region: str,
    now: datetime,
) -> List[Dict[str, str]]:
    out: List[Dict[str, str]] = []

    # Application / Network / Gateway Load Balancers
    try:
        paginator = elbv2.get_paginator("describe_load_balancers")
        for page in paginator.paginate():
            for lb in page.get("LoadBalancers", []):
                created = lb.get("CreatedTime")
                if isinstance(created, datetime) and created.tzinfo is None:
                    created = created.replace(tzinfo=timezone.utc)
                lb_arn = lb["LoadBalancerArn"]
                registered, healthy = _elb_v2_target_counts(elbv2, lb_arn)
                if registered > 0 and healthy > 0:
                    continue
                if registered == 0:
                    detail = "no-targets"
                else:
                    detail = f"no-healthy-targets/{registered}-registered"
                name = lb.get("LoadBalancerName") or "N/A"
                out.append(
                    row(
                        "elb",
                        account_id,
                        account_name,
                        profile,
                        region,
                        lb_arn,
                        name,
                        detail,
                        age=age_days(created, now) if isinstance(created, datetime) else None,
                        when=created if isinstance(created, datetime) else None,
                        extra=(
                            f"type={lb.get('Type') or 'N/A'};"
                            f"scheme={lb.get('Scheme') or 'N/A'};"
                            f"state={(lb.get('State') or {}).get('Code') or 'N/A'}"
                        ),
                    )
                )
    except (ClientError, BotoCoreError) as exc:
        eprint(f"    elbv2: {exc}")

    # Classic Load Balancers
    try:
        paginator = elb.get_paginator("describe_load_balancers")
        for page in paginator.paginate():
            for lb in page.get("LoadBalancerDescriptions", []):
                name = lb.get("LoadBalancerName") or "N/A"
                created = lb.get("CreatedTime")
                if isinstance(created, datetime) and created.tzinfo is None:
                    created = created.replace(tzinfo=timezone.utc)
                instances = lb.get("Instances") or []
                registered = len(instances)
                healthy = 0
                if instances:
                    try:
                        health = elb.describe_instance_health(LoadBalancerName=name)
                        for ih in health.get("InstanceStates", []):
                            if ih.get("State") == "InService":
                                healthy += 1
                    except (ClientError, BotoCoreError):
                        pass
                if registered > 0 and healthy > 0:
                    continue
                if registered == 0:
                    detail = "no-targets"
                else:
                    detail = f"no-healthy-targets/{registered}-registered"
                out.append(
                    row(
                        "elb",
                        account_id,
                        account_name,
                        profile,
                        region,
                        name,
                        name,
                        detail,
                        age=age_days(created, now) if isinstance(created, datetime) else None,
                        when=created if isinstance(created, datetime) else None,
                        extra="type=classic;scheme=" + (lb.get("Scheme") or "N/A"),
                    )
                )
    except (ClientError, BotoCoreError) as exc:
        eprint(f"    classic-elb: {exc}")

    return out


def scan_ami(
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
    images = ec2.describe_images(Owners=["self"]).get("Images", [])
    for image in images:
        created_raw = image.get("CreationDate")
        created: Optional[datetime] = None
        if created_raw:
            try:
                created = datetime.fromisoformat(created_raw.replace("Z", "+00:00"))
            except ValueError:
                created = None
        if created is None or created >= cutoff:
            continue
        snap_ids = []
        for bdm in image.get("BlockDeviceMappings") or []:
            ebs = bdm.get("Ebs") or {}
            if ebs.get("SnapshotId"):
                snap_ids.append(ebs["SnapshotId"])
        out.append(
            row(
                "ami",
                account_id,
                account_name,
                profile,
                region,
                image["ImageId"],
                image.get("Name") or tag_name(image.get("Tags")),
                image.get("Description") or "N/A",
                age=age_days(created, now),
                when=created,
                extra=(
                    f"state={image.get('State') or 'N/A'};"
                    f"public={image.get('Public')};"
                    f"snapshots={','.join(snap_ids) or 'N/A'}"
                ),
            )
        )
    return out


def scan_logs(
    logs,
    *,
    account_id: str,
    account_name: str,
    profile: str,
    region: str,
    now: datetime,
    min_gib: float,
) -> List[Dict[str, str]]:
    out: List[Dict[str, str]] = []
    paginator = logs.get_paginator("describe_log_groups")
    for page in paginator.paginate():
        for group in page.get("logGroups", []):
            retention = group.get("retentionInDays")
            stored = float(group.get("storedBytes") or 0)
            size_gib = stored / (1024.0 ** 3)
            never_expire = retention is None
            oversized = size_gib >= min_gib
            if not never_expire and not oversized:
                continue
            reasons = []
            if never_expire:
                reasons.append("never-expire")
            if oversized:
                reasons.append(f"size>={min_gib:g}GiB")
            created_ms = group.get("creationTime")
            created = None
            if created_ms is not None:
                created = datetime.fromtimestamp(created_ms / 1000.0, tz=timezone.utc)
            out.append(
                row(
                    "logs",
                    account_id,
                    account_name,
                    profile,
                    region,
                    group.get("logGroupName") or "N/A",
                    group.get("logGroupName") or "N/A",
                    "+".join(reasons),
                    age=age_days(created, now) if created else None,
                    when=created,
                    size_gib=round(size_gib, 3),
                    extra=(
                        f"retention={retention if retention is not None else 'Never'};"
                        f"storedBytes={int(stored)}"
                    ),
                )
            )
    return out


def _run_check(label: str, region: str, fn) -> List[Dict[str, str]]:
    try:
        return fn()
    except (ClientError, BotoCoreError) as exc:
        eprint(f"  [{region}] {label}: {exc}")
        return []


def scan_profile(
    profile: str,
    regions: Sequence[str],
    services: Sequence[str],
    *,
    snapshot_cutoff: datetime,
    stopped_cutoff: datetime,
    ami_cutoff: datetime,
    log_min_gib: float,
    nat_idle_days: int,
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
    base = dict(account_id=account_id, account_name=account_name, profile=profile)

    for region in regions:
        eprint(f"  [{region}] scanning: {', '.join(services)}")
        ec2 = session.client("ec2", region_name=region)

        if "snapshots" in services:
            findings.extend(
                _run_check(
                    "snapshots",
                    region,
                    lambda: scan_snapshots(
                        ec2, region=region, cutoff=snapshot_cutoff, now=now, **base
                    ),
                )
            )
        if "volumes" in services:
            findings.extend(
                _run_check(
                    "volumes",
                    region,
                    lambda: scan_volumes(ec2, region=region, now=now, **base),
                )
            )
        if "eip" in services:
            findings.extend(
                _run_check(
                    "eip",
                    region,
                    lambda: scan_eips(ec2, region=region, **base),
                )
            )
        if "stopped" in services:
            findings.extend(
                _run_check(
                    "stopped",
                    region,
                    lambda: scan_stopped(
                        ec2, region=region, cutoff=stopped_cutoff, now=now, **base
                    ),
                )
            )
        if "nat" in services:
            cw = session.client("cloudwatch", region_name=region)
            findings.extend(
                _run_check(
                    "nat",
                    region,
                    lambda: scan_nat(
                        ec2,
                        cw,
                        region=region,
                        now=now,
                        idle_days=nat_idle_days,
                        **base,
                    ),
                )
            )
        if "elb" in services:
            elbv2 = session.client("elbv2", region_name=region)
            elb = session.client("elb", region_name=region)
            findings.extend(
                _run_check(
                    "elb",
                    region,
                    lambda: scan_elb(
                        elbv2, elb, region=region, now=now, **base
                    ),
                )
            )
        if "ami" in services:
            findings.extend(
                _run_check(
                    "ami",
                    region,
                    lambda: scan_ami(
                        ec2, region=region, cutoff=ami_cutoff, now=now, **base
                    ),
                )
            )
        if "logs" in services:
            logs = session.client("logs", region_name=region)
            findings.extend(
                _run_check(
                    "logs",
                    region,
                    lambda: scan_logs(
                        logs, region=region, now=now, min_gib=log_min_gib, **base
                    ),
                )
            )

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
  Services:  --allservices | one or more of """
            + SERVICE_FLAGS
            + """

Examples:
  %(prog)s --allaccounts --allservices
  %(prog)s --account IIQ-Corp --snapshots --eip
  %(prog)s --account IIQ-Corp-RO --nat --elb --logs
  %(prog)s --allaccounts --ami --ami-age 90d
  %(prog)s --allaccounts --allservices -o hygiene-report.csv

Notes:
  - Only profiles ending in -RO are used.
  - Default regions: us-east-1 us-east-2 us-west-1 us-west-2 eu-west-2 ca-central-1
  - --region replaces the default region list (repeatable / space-separated).
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
        help="Run all script checks: " + ", ".join(SERVICES),
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
    services.add_argument(
        "--nat",
        action="store_true",
        help=(
            "NAT gateways (all listed; Detail marks idle when "
            f"BytesOutToDestination is 0 over --nat-idle-days, default {DEFAULT_NAT_IDLE_DAYS}d)"
        ),
    )
    services.add_argument(
        "--elb",
        action="store_true",
        help="ALB/NLB/CLB with no targets or no healthy targets",
    )
    services.add_argument(
        "--ami",
        action="store_true",
        help=f"Self-owned AMIs older than --ami-age (default {DEFAULT_AMI_AGE_DAYS}d)",
    )
    services.add_argument(
        "--logs",
        action="store_true",
        help=(
            "CloudWatch log groups with never-expire retention and/or "
            f"stored size >= --log-min-gib (default {DEFAULT_LOG_MIN_GIB:g} GiB)"
        ),
    )

    parser.add_argument(
        "--region",
        dest="regions",
        action="append",
        nargs="+",
        metavar="REGION",
        help=(
            "Region(s) to scan instead of the default region list. "
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
        "--ami-age",
        default=f"{DEFAULT_AMI_AGE_DAYS}d",
        type=lambda v: parse_duration_days(v, "--ami-age"),
        metavar="DAYS",
        help=f"AMI age threshold (default: {DEFAULT_AMI_AGE_DAYS}d)",
    )
    parser.add_argument(
        "--nat-idle-days",
        default=f"{DEFAULT_NAT_IDLE_DAYS}d",
        type=lambda v: parse_duration_days(v, "--nat-idle-days"),
        metavar="DAYS",
        help=(
            "CloudWatch window for NAT BytesOutToDestination idle check "
            f"(default: {DEFAULT_NAT_IDLE_DAYS}d)"
        ),
    )
    parser.add_argument(
        "--log-min-gib",
        type=float,
        default=DEFAULT_LOG_MIN_GIB,
        metavar="GiB",
        help=(
            "Also flag log groups at/above this stored size even if retention is set "
            f"(default: {DEFAULT_LOG_MIN_GIB:g})"
        ),
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
        errors.append(f"choose --allservices or one/more of {SERVICE_FLAGS}")
    if args.allservices and individual:
        errors.append("use --allservices alone, or individual service flags (not both)")
    if args.log_min_gib < 0:
        errors.append("--log-min-gib must be >= 0")

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
        "Thresholds: "
        f"snapshots>{args.snapshot_age}d  stopped>{args.stopped_age}d  "
        f"ami>{args.ami_age}d  nat-idle={args.nat_idle_days}d  "
        f"log-min={args.log_min_gib:g}GiB"
    )

    ensure_sso(profiles[0])

    now = datetime.now(timezone.utc)
    snapshot_cutoff = now - timedelta(days=args.snapshot_age)
    stopped_cutoff = now - timedelta(days=args.stopped_age)
    ami_cutoff = now - timedelta(days=args.ami_age)

    all_rows: List[Dict[str, str]] = []
    for profile in profiles:
        all_rows.extend(
            scan_profile(
                profile,
                regions,
                services,
                snapshot_cutoff=snapshot_cutoff,
                stopped_cutoff=stopped_cutoff,
                ami_cutoff=ami_cutoff,
                log_min_gib=args.log_min_gib,
                nat_idle_days=args.nat_idle_days,
                now=now,
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
