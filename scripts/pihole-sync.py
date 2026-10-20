#!/usr/bin/env python3
"""Bring a Pi-hole v6 to the state in group_vars/pihole.yml.

    pihole-sync.py plan   STATE_B64   what would change, as JSON; changes nothing
    pihole-sync.py apply  STATE_B64   make those changes, print the same JSON
    pihole-sync.py verify STATE_B64   ask 127.0.0.1: a normal name resolves, a
                                      gravity domain and every exact deny
                                      entry come back blocked (0.0.0.0)
    pihole-sync.py ask NAME SERVER... ask other servers for NAME: {SERVER:
                                      addresses or error}, "answering": count

STATE_B64 is base64 JSON (no quoting trouble on a command line):

    {"settings": {"dns.upstreams": ["8.8.8.8"], "dns.queryLogging": true},
     "adlists":  ["https://..."],
     "domains":  {"allow": [], "deny": [], "allow_regex": [], "deny_regex": []},
     "verify_name": "example.com"}

Settings are read from /etc/pihole/pihole.toml and written with
`pihole-FTL --config KEY VALUE`, FTL's own way to change them. Only the keys
in the state are touched. Blocklists and domains are the whole truth: rows
in gravity.db that the state doesn't list are removed. The caller runs
`pihole -g` when "gravity" is true (blocklists changed) and `pihole
reloadlists` when "reload" is true (domains changed).

Standard library only (Python 3.11+ for tomllib): it runs on the Pi-holes
through Ansible's script module.
"""
import base64
import json
import random
import socket
import sqlite3
import struct
import subprocess
import sys
import tomllib

TOML = "/etc/pihole/pihole.toml"
GRAVITY_DB = "/etc/pihole/gravity.db"
COMMENT = "Managed by ~/Code/bind (group_vars/pihole.yml)"
# domainlist.type
DOMAIN_TYPES = {"allow": 0, "deny": 1, "allow_regex": 2, "deny_regex": 3}
MISSING = object()


def current_setting(toml, key):
    node = toml
    for part in key.split("."):
        if not isinstance(node, dict) or part not in node:
            return MISSING
        node = node[part]
    return node


def plan(state):
    with open(TOML, "rb") as f:
        toml = tomllib.load(f)
    out = {"settings": [], "adlists": {"add": [], "remove": [], "enable": []},
           "domains": {"add": [], "remove": [], "enable": []}}

    for key, want in state.get("settings", {}).items():
        have = current_setting(toml, key)
        if have is MISSING:
            raise SystemExit(f"{key} is not a setting in this Pi-hole's {TOML} (wrong name, or another FTL version)")
        if have != want:
            out["settings"].append({"key": key, "from": have, "to": want})

    db = sqlite3.connect(f"file:{GRAVITY_DB}?mode=ro", uri=True)
    # Blocklists (type 0). Allowlist-type lists aren't managed here, and are left alone.
    rows = {a: e for a, e in db.execute("SELECT address, enabled FROM adlist WHERE type = 0")}
    want = state.get("adlists", [])
    out["adlists"]["add"] = [a for a in want if a not in rows]
    out["adlists"]["enable"] = [a for a in want if a in rows and not rows[a]]
    out["adlists"]["remove"] = sorted(a for a in rows if a not in want)

    rows = {(d, t): e for d, t, e in db.execute("SELECT domain, type, enabled FROM domainlist")}
    want = {(d, DOMAIN_TYPES[k]) for k, ds in state.get("domains", {}).items() for d in ds}
    names = {v: k for k, v in DOMAIN_TYPES.items()}
    fmt = lambda dt: {"domain": dt[0], "list": names[dt[1]]}
    out["domains"]["add"] = [fmt(dt) for dt in sorted(want - rows.keys())]
    out["domains"]["enable"] = [fmt(dt) for dt in sorted(want & rows.keys()) if not rows[dt]]
    out["domains"]["remove"] = [fmt(dt) for dt in sorted(rows.keys() - want)]
    db.close()

    out["gravity"] = any(out["adlists"].values())
    out["reload"] = any(out["domains"].values())
    out["changed"] = bool(out["settings"]) or out["gravity"] or out["reload"]
    return out


def ftl_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (list, dict)):
        return json.dumps(v)
    return str(v)


def apply(state):
    p = plan(state)
    for s in p["settings"]:
        r = subprocess.run(["pihole-FTL", "--config", s["key"], ftl_value(s["to"])],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit(f"pihole-FTL --config {s['key']} failed: {(r.stdout + r.stderr).strip()}")

    if p["gravity"] or p["reload"]:
        db = sqlite3.connect(GRAVITY_DB)
        with db:
            for a in p["adlists"]["add"]:
                db.execute("INSERT INTO adlist (address, type, comment) VALUES (?, 0, ?)", (a, COMMENT))
            for a in p["adlists"]["enable"]:
                db.execute("UPDATE adlist SET enabled = 1 WHERE address = ? AND type = 0", (a,))
            for a in p["adlists"]["remove"]:
                db.execute("DELETE FROM adlist WHERE address = ? AND type = 0", (a,))
            for d in p["domains"]["add"]:
                db.execute("INSERT INTO domainlist (domain, type, comment) VALUES (?, ?, ?)",
                           (d["domain"], DOMAIN_TYPES[d["list"]], COMMENT))
            for d in p["domains"]["enable"]:
                db.execute("UPDATE domainlist SET enabled = 1 WHERE domain = ? AND type = ?",
                           (d["domain"], DOMAIN_TYPES[d["list"]]))
            for d in p["domains"]["remove"]:
                db.execute("DELETE FROM domainlist WHERE domain = ? AND type = ?",
                           (d["domain"], DOMAIN_TYPES[d["list"]]))
        db.close()

    left = plan(state)
    if left["changed"]:
        raise SystemExit(f"still differs after apply: {json.dumps(left)}")
    return p


def ask(name, server="127.0.0.1", timeout=2.0):
    """A records for name, or raise."""
    qid = random.randrange(1 << 16)
    q = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    q += b"".join(bytes([len(p)]) + p.encode() for p in name.rstrip(".").split(".")) + b"\0"
    q += struct.pack(">HH", 1, 1)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.settimeout(timeout)
        for _ in range(3):
            try:
                s.sendto(q, (server, 53))
                msg, _ = s.recvfrom(4096)
            except socket.timeout:
                continue
            rid, flags, qd, an = struct.unpack(">HHHH", msg[:8])
            if rid != qid:
                continue
            if flags & 0xF:
                raise RuntimeError(f"rcode {flags & 0xF}")
            i = 12
            for _ in range(qd):
                i = skip_name(msg, i) + 4
            addrs = []
            for _ in range(an):
                i = skip_name(msg, i)
                rtype, _, _, rdlen = struct.unpack(">HHIH", msg[i:i + 10])
                i += 10
                if rtype == 1:
                    addrs.append(socket.inet_ntoa(msg[i:i + 4]))
                i += rdlen
            return addrs
    raise RuntimeError("timeout")


def skip_name(msg, i):
    while True:
        n = msg[i]
        if n == 0:
            return i + 1
        if n & 0xC0 == 0xC0:
            return i + 2
        i += n + 1


def verify(state):
    db = sqlite3.connect(f"file:{GRAVITY_DB}?mode=ro", uri=True)
    allowed = set(state.get("domains", {}).get("allow", []))
    # Skip the hosts-file boilerplate at the top of most lists (localhost,
    # broadcasthost, ...): blocked, but proving nothing about ad blocking.
    gravity = next((d for (d,) in db.execute(
        "SELECT domain FROM gravity WHERE domain NOT LIKE '%local%' AND domain LIKE '%.%.%' LIMIT 50")
        if d not in allowed), None)
    db.close()
    checks = [(state.get("verify_name", "example.com"), "resolves")]
    if gravity:
        checks.append((gravity, "blocked"))
    checks += [(d, "blocked") for d in state.get("domains", {}).get("deny", [])]
    results, ok = [], True
    for name, want in checks:
        try:
            addrs = ask(name)
            blocked = addrs == ["0.0.0.0"]
            good = blocked if want == "blocked" else bool(addrs) and not blocked
            got = ",".join(addrs) or "no A records"
        except RuntimeError as e:
            good, got = False, str(e)
        ok &= good
        results.append({"name": name, "want": want, "got": got, "ok": good})
    return {"ok": ok, "checks": results}


def ask_servers(name, servers):
    out = {"servers": {}}
    for server in servers:
        try:
            out["servers"][server] = ",".join(ask(name, server)) or "no A records"
        except (RuntimeError, OSError) as e:
            out["servers"][server] = f"FAIL ({e})"
    out["answering"] = sum(1 for v in out["servers"].values() if v[:1].isdigit() and v != "0.0.0.0")
    return out


def main(argv):
    if argv[:1] == ["ask"] and len(argv) >= 2:
        print(json.dumps(ask_servers(argv[1], argv[2:])))
        return 0
    if len(argv) != 2 or argv[0] not in ("plan", "apply", "verify"):
        raise SystemExit(__doc__)
    state = json.loads(base64.b64decode(argv[1]))
    result = {"plan": plan, "apply": apply, "verify": verify}[argv[0]](state)
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
