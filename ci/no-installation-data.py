#!/usr/bin/env python3
"""Fail if the template contains data of a real installation.

The template must stay blank: every example uses example.org, the
documentation IP ranges and change-me. This scans the repository for
  - IPv4 addresses outside the documentation ranges (RFC 5737), the example
    private range 10.0.0.0/24, the k3s pod and Service CIDRs, loopback and
    the public resolvers used as defaults;
  - e-mail addresses outside example domains;
  - image tags "latest".

  python3 ci/no-installation-data.py [path ...]
"""

import ipaddress
import pathlib
import re
import sys

ALLOWED_NETS = [ipaddress.ip_network(n) for n in (
    "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24",  # documentation
    "10.0.0.0/24",                                       # example nodes
    "10.42.0.0/16", "10.43.0.0/16",                      # k3s pod/Service CIDRs
    "127.0.0.0/8", "0.0.0.0/32",
    "1.1.1.1/32", "8.8.8.8/32",                          # default DNS-01 resolvers
)]
ALLOWED_MAIL = re.compile(r"@(example\.(org|com|net)|[a-z0-9.-]*\.example(\.[a-z]+)?|conservices\.test)$", re.I)
IP = re.compile(r"(?<![\d.])(\d{1,3}(?:\.\d{1,3}){3})(?:/\d{1,2})?(?![\d.])")
MAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
LATEST = re.compile(r"(image:\s*\S+:latest\b|tag:\s*[\"']?latest[\"']?\s*$|targetRevision:\s*latest\b)")
SKIP_DIRS = {".git", "node_modules", "site", "build"}
TEXT = {".yaml", ".yml", ".json", ".md", ".sh", ".py", ".toml", ".tpl", ".txt", ".ftl",
        ".properties", ".css", ".js", ".conf", ""}


def version_like(line, ip):
    # "1.20.4.1"-style version strings are not addresses; addresses in URLs
    # or YAML are preceded by a space, quote, slash, colon, @ or bracket.
    i = line.find(ip)
    return i > 0 and line[i - 1] in "v-_"


def generic_block(cidr):
    # Whole private, shared or link-local ranges (10.0.0.0/8, 172.16.0.0/12,
    # 100.64.0.0/10, ...) in network policies say nothing about one site.
    try:
        net = ipaddress.ip_network(cidr, strict=True)
    except ValueError:
        return False
    return net.prefixlen <= 16 and (net.is_private or net.is_link_local
                                    or net.subnet_of(ipaddress.ip_network("100.64.0.0/10")))


def scan(path, errors):
    if path.resolve() == pathlib.Path(__file__).resolve():
        return
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return
    for n, line in enumerate(text.splitlines(), 1):
        for m in IP.finditer(line):
            ip = m.group(1)
            try:
                addr = ipaddress.ip_address(ip)
            except ValueError:
                continue
            if version_like(line, ip) or any(addr in net for net in ALLOWED_NETS):
                continue
            if m.group(0) != ip and generic_block(m.group(0)):
                continue
            errors.append(f"{path}:{n}: IP address {ip} (use 192.0.2.x, 198.51.100.x, 203.0.113.x or 10.0.0.x)")
        for m in MAIL.finditer(line):
            if not ALLOWED_MAIL.search(m.group(0)) and not m.group(0).startswith("git@"):
                errors.append(f"{path}:{n}: e-mail address {m.group(0)} (use an example.org address)")
        if LATEST.search(line):
            errors.append(f"{path}:{n}: 'latest' tag (pin an exact version)")


def main():
    roots = [pathlib.Path(p) for p in (sys.argv[1:] or ["."])]
    errors = []
    for root in roots:
        files = [root] if root.is_file() else root.rglob("*")
        for f in files:
            if f.is_file() and f.suffix in TEXT and not SKIP_DIRS.intersection(f.parts):
                scan(f, errors)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        sys.exit(1)
    print("no installation data found")


if __name__ == "__main__":
    main()
