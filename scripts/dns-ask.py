#!/usr/bin/env python3
"""Ask each given DNS server for example.com A over UDP; one line per server.

    scripts/dns-ask.py SERVER [SERVER...] [--name example.com]

Prints `ok SERVER` or `FAIL SERVER (reason)` and always exits 0: preflight
decides what's fatal. Standard library only, because it runs on the servers
(by Ansible's script module), where dig may not be installed.
"""
import random
import socket
import struct
import sys


def ask(server, name, timeout=2.0):
    qid = random.randrange(1 << 16)
    header = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)  # recursion desired
    question = b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\0"
    packet = header + question + struct.pack(">HH", 1, 1)  # A, IN
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.settimeout(timeout)
        for _ in range(2):
            try:
                s.sendto(packet, (server, 53))
                reply, _ = s.recvfrom(4096)
            except socket.timeout:
                continue
            except OSError as e:
                return str(e)
            rid, flags, _, ancount = struct.unpack(">HHHH", reply[:8])
            if rid != qid:
                continue
            rcode = flags & 0xF
            if rcode != 0:
                return f"rcode {rcode}"
            return None if ancount else "no answer"
    return "timeout"


def main(argv):
    name = "example.com"
    if "--name" in argv:
        i = argv.index("--name")
        name = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    for server in argv:
        err = ask(server, name)
        print(f"ok {server}" if err is None else f"FAIL {server} ({err})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
