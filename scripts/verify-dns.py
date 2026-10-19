#!/usr/bin/env python3
"""Ask a running server for every record in records.yaml and compare.

This replaces build.sh's and remote-validate.sh's loops, which printed
SUCCESS for any name because `dig +short` exits 0 even on NXDOMAIN. Here a
record passes only if the answer contains the value records.yaml gives.

    scripts/verify-dns.py SERVER [--port 53] [--records records.yaml] [--no-recursion-check]

Also checks the SOA and NS, and that recursion through the forwarders works
(the LAN uses this server for everything, not just the zone).
"""
import argparse
import subprocess
import sys

import yaml


def dig(server, port, name, rtype):
    out = subprocess.run(
        ["dig", "+short", "+time=3", "+tries=2", "-p", str(port), f"@{server}", name, rtype],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        return None
    return [line.strip() for line in out.stdout.splitlines() if line.strip()]


def fqdn(value, zone):
    value = str(value)
    return value if value.endswith(".") else f"{value}.{zone}."


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("server")
    ap.add_argument("--port", type=int, default=53)
    ap.add_argument("--records", default="records.yaml")
    ap.add_argument("--no-recursion-check", action="store_true")
    args = ap.parse_args()

    data = yaml.safe_load(open(args.records))
    zone = data["zone"]
    failures = 0

    def check(label, ok, got):
        nonlocal failures
        print(f"  {'ok  ' if ok else 'FAIL'} {label}" + ("" if ok else f"  (got {got or 'nothing'})"))
        failures += 0 if ok else 1

    soa = dig(args.server, args.port, zone, "SOA") or []
    check(f"{zone} SOA", any(s.startswith(data["soa"]["primary_ns"]) for s in soa), soa)
    ns = dig(args.server, args.port, zone, "NS") or []
    for want_ns in data["soa"].get("nameservers") or [data["soa"]["primary_ns"]]:
        check(f"{zone} NS {want_ns}", want_ns in ns, ns)

    for r in data["records"]:
        name = f"{r['name']}.{zone}" if r["name"] != "@" else zone
        want = fqdn(r["value"], zone) if r["type"] == "CNAME" else str(r["value"])
        got = dig(args.server, args.port, name, r["type"])
        check(f"{name} {r['type']} {want}", got is not None and want in got, got)

    if not args.no_recursion_check:
        got = dig(args.server, args.port, "example.com", "A")
        check("recursion: example.com A (through the forwarders)", bool(got), got)

    print(f"{failures} failed" if failures else "all records answer as records.yaml says")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
