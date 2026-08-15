#!/usr/bin/env python3
"""scripts/update_lists.py — refresh lists/custom/*.lst and lists/ip/*.lst
from scripts/seeds.json, and print a Markdown changelog of what moved.

For every candidate domain of every watched service:
  1. Resolve it (DNS). Dead domains are dropped and reported.
  2. "Ping" it -- in practice a TCP+TLS reachability check on :443, since raw
     ICMP is routinely firewalled in CI/cloud runners and wouldn't be a
     reliable liveness signal there.
  3. Alive domains go into lists/custom/<key>.lst *only* for services marked
     "routing": true in seeds.json (the ones actually missing from Xray's
     geosite database -- see README). Every service, routing or not, also
     gets its resolved IPv4 addresses written to lists/ip/<key>.lst as a
     dated, informational snapshot (NOT used for routing -- CDN-backed
     services rotate edge IPs constantly, so a periodic DNS snapshot is
     inherently incomplete; routing itself stays domain-based).

Run locally:  python3 scripts/update_lists.py [--dry-run]
Used by:      .github/workflows/update-domain-lists.yml (weekly + manual)

Exit code 0 always (failures are reported per-domain, not fatal); prints a
Markdown summary to stdout, and if $GITHUB_OUTPUT is set, writes
`has_changes` (true/false) and a multi-line `notes` output for the workflow
to hand to `gh release create --notes-file`.
"""
import json
import os
import socket
import ssl
import sys
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEEDS_PATH = os.path.join(ROOT, "scripts", "seeds.json")
CUSTOM_DIR = os.path.join(ROOT, "lists", "custom")
IP_DIR = os.path.join(ROOT, "lists", "ip")
TIMEOUT = 5


def check_domain(domain, attempts=3):
    """Return (alive: bool, ipv4_addrs: set[str]).

    Retries a few times before declaring a candidate dead -- a single failed
    TCP/TLS probe is often just a transient network hiccup (especially from
    a CI runner), not proof the service is actually gone. Reduces spurious
    diffs/releases caused by one-off connect timeouts.
    """
    ips = set()
    try:
        infos = socket.getaddrinfo(domain, 443, family=socket.AF_INET, type=socket.SOCK_STREAM)
    except socket.gaierror:
        return False, ips
    for info in infos:
        ips.add(info[4][0])

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    for _ in range(attempts):
        for ip in ips:
            try:
                with socket.create_connection((ip, 443), timeout=TIMEOUT) as sock:
                    with ctx.wrap_socket(sock, server_hostname=domain):
                        return True, ips
            except OSError:
                continue
    return False, ips


def read_lines(path):
    if not os.path.exists(path):
        return set()
    out = set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                out.add(line)
    return out


def write_list(path, header_lines, entries):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        for h in header_lines:
            f.write("# " + h + "\n")
        for e in sorted(entries):
            f.write(e + "\n")


def main():
    dry_run = "--dry-run" in sys.argv
    with open(SEEDS_PATH, encoding="utf-8") as f:
        seeds = json.load(f)

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    changelog = []   # list of markdown bullet strings
    any_change = False

    for key, spec in sorted(seeds["services"].items()):
        label = spec.get("label", key)
        routing = bool(spec.get("routing", False))
        candidates = spec.get("candidates", [])

        alive_domains = []
        dead_domains = []
        all_ips = set()
        for d in candidates:
            ok, ips = check_domain(d)
            all_ips |= ips
            (alive_domains if ok else dead_domains).append(d)

        # --- IP snapshot (all services) ---
        ip_path = os.path.join(IP_DIR, f"{key}.lst")
        old_ips = read_lines(ip_path)
        added_ips = all_ips - old_ips
        removed_ips = old_ips - all_ips
        if all_ips != old_ips:
            any_change = True
            if not dry_run:
                write_list(ip_path, [
                    f"{label} -- resolved IPv4 snapshot, auto-generated {now} by scripts/update_lists.py",
                    "Informational only: NOT used for routing (CDN IPs rotate; this is a point-in-time DNS snapshot).",
                    f"source domains: {', '.join(candidates)}",
                ], all_ips)
            changelog.append(
                f"- **{label}** (`lists/ip/{key}.lst`): {len(all_ips)} IP(s) total "
                f"(+{len(added_ips)} / -{len(removed_ips)})"
            )

        # --- domain list used for actual routing (routing:true services only) ---
        if routing:
            custom_path = os.path.join(CUSTOM_DIR, f"{key}.lst")
            old_domains = read_lines(custom_path)
            new_domains = set(alive_domains)
            if new_domains != old_domains:
                any_change = True
                added_d = new_domains - old_domains
                removed_d = old_domains - new_domains
                if not dry_run:
                    header = [f"{label} -- auto-verified {now} by scripts/update_lists.py (candidates from scripts/seeds.json)"]
                    if dead_domains:
                        header.append("dropped as unreachable this run: " + ", ".join(dead_domains))
                    write_list(custom_path, header, new_domains)
                changelog.append(
                    f"- **{label}** (`lists/custom/{key}.lst`, routed): {len(new_domains)} domain(s) "
                    f"(+{len(added_d)} / -{len(removed_d)})"
                )

        print(f"[{key}] alive={len(alive_domains)} dead={len(dead_domains)} ips={len(all_ips)} routing={routing}",
              file=sys.stderr)

    if changelog:
        notes = "## Domain/IP list update — " + now + "\n\n" + "\n".join(changelog) + "\n"
    else:
        notes = f"## Domain/IP list update — {now}\n\nNo changes this run.\n"

    print(notes)

    # Written to a plain file rather than a GITHUB_OUTPUT string: the notes
    # contain backticks/markdown that would break shell quoting if piped
    # through a `${{ }}` expression embedded in a workflow `run:` script.
    with open(os.path.join(ROOT, "RELEASE_NOTES.md"), "w", encoding="utf-8", newline="\n") as f:
        f.write(notes)

    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a", encoding="utf-8") as f:
            f.write(f"has_changes={'true' if any_change else 'false'}\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
