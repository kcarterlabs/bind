#!/usr/bin/env python3
"""Lint records.yaml before anything renders it.

named-checkzone (run by `make validate` and by bind-reload in the container)
catches what BIND rejects. This catches what BIND would happily serve but is
still a mistake: a duplicated name, a typo'd IP, a CNAME next to an A.

    scripts/check-records.py [records.yaml]

Exit 0 if clean, 1 with one line per problem otherwise.
"""
import ipaddress
import re
import sys

import yaml

LABEL = re.compile(r"^(?!-)[a-z0-9-]{1,63}(?<!-)$")
TYPES = {"A", "AAAA", "CNAME", "TXT", "MX", "NS", "SRV", "CAA"}
SOA_KEYS = ("primary_ns", "admin_email", "refresh", "retry", "expire", "minimum")


def main(path):
    with open(path) as f:
        data = yaml.safe_load(f)
    problems = []

    if not isinstance(data, dict) or not data.get("zone"):
        return [f"{path}: no `zone:`"]
    soa = data.get("soa") or {}
    for key in SOA_KEYS:
        if key not in soa:
            problems.append(f"soa: missing {key}")
    serial = soa.get("serial", "auto")
    if serial != "auto" and not (isinstance(serial, int) and 0 < serial < 2**32):
        problems.append(f"soa: serial must be `auto` or a 32-bit number, not {serial!r}")

    by_name = {}
    for i, r in enumerate(data.get("records") or [], 1):
        where = f"record {i} ({r.get('name', '?')})"
        name, rtype, value = r.get("name"), r.get("type"), r.get("value")
        if name is None or rtype is None or value is None:
            problems.append(f"{where}: needs name, type and value")
            continue
        name = str(name)
        if name != "@" and not all(LABEL.match(label) for label in name.split(".")):
            problems.append(f"{where}: `{name}` is not a valid lower-case host name")
        if rtype not in TYPES:
            problems.append(f"{where}: unknown type {rtype}")
        ttl = r.get("ttl")
        if ttl is not None and not (isinstance(ttl, int) and ttl > 0):
            problems.append(f"{where}: ttl must be a positive integer")

        if rtype == "A":
            try:
                ipaddress.IPv4Address(str(value))
            except ValueError:
                problems.append(f"{where}: `{value}` is not an IPv4 address")
        elif rtype == "AAAA":
            try:
                ipaddress.IPv6Address(str(value))
            except ValueError:
                problems.append(f"{where}: `{value}` is not an IPv6 address")
        elif rtype == "CNAME":
            target = str(value).rstrip(".")
            if not all(LABEL.match(label) for label in target.split(".")):
                problems.append(f"{where}: CNAME target `{value}` is not a host name")

        by_name.setdefault(name.lower(), []).append((rtype, str(value), where))

    for name, entries in by_name.items():
        types = [t for t, _, _ in entries]
        if "CNAME" in types and len(entries) > 1:
            problems.append(f"`{name}`: a CNAME can't share its name with other records "
                            f"({', '.join(w for _, _, w in entries)})")
        seen = set()
        for rtype, value, where in entries:
            if (rtype, value) in seen:
                problems.append(f"{where}: duplicate of an earlier `{name}` {rtype} {value}")
            seen.add((rtype, value))
    return problems


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "records.yaml"
    problems = main(path)
    for p in problems:
        print(f"{path}: {p}", file=sys.stderr)
    if problems:
        sys.exit(1)
    print(f"{path}: OK")
