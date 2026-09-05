#!/usr/bin/env python3
"""
Summarize an iPhone packet capture to explain how Instagram reaches its CDN.

Answers, from one pcap:
  * which DNS queries/answers happened (and to which resolver),
  * whether DNS-over-HTTPS/TLS candidates are present,
  * which TLS/QUIC SNI names were used (Wireshark decrypts QUIC Initials),
  * for the heaviest destination IPs: were they obtained from a DNS answer
    in this capture (provenance), what SNI was presented, how many bytes.

Usage: summarize-capture.py capture.pcap [--tshark /path/to/tshark] [--top 15]
"""
import argparse
import collections
import re
import socket
import subprocess
import sys

META = re.compile(r"fbcdn|cdninstagram|instagram|facebook|fbsbx|whatsapp|tiktok|bytedance|byteoversea|bytedtos|byteimg|byteicdn|bytefcdn|musical", re.I)
DOH_SNI = re.compile(r"(^|\.)(dns|doh|resolver|dot)[.\-]|dns\.google|cloudflare-dns|one\.one\.one", re.I)
KNOWN_RESOLVER_IPS = {"8.8.8.8", "8.8.4.4", "1.1.1.1", "1.0.0.1", "9.9.9.9", "149.112.112.112",
                      "2001:4860:4860::8888", "2001:4860:4860::8844", "2606:4700:4700::1111"}


def tshark(args, tshark_bin, pcap):
    cmd = [tshark_bin, "-r", pcap, "-n", "-T", "fields", "-E", "separator=|", "-E", "occurrence=a",
           "-E", "aggregator=;"] + args
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0 and not out.stdout:
        sys.stderr.write(out.stderr)
    return [line.split("|") for line in out.stdout.splitlines()]


def first(v):
    return v.split(";")[0] if v else ""


def is_local_or_multicast(addr):
    """Multicast, link-local and broadcast addresses aren't hosts we care about."""
    if not addr:
        return True
    if ":" in addr:
        return addr.lower().startswith(("ff", "fe80"))
    o = addr.split(".")
    return addr == "255.255.255.255" or (o[0].isdigit() and 224 <= int(o[0]) <= 239) or addr.startswith("169.254.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pcap")
    ap.add_argument("--tshark", default="tshark")
    ap.add_argument("--top", type=int, default=15)
    a = ap.parse_args()

    # ---- all IP frames: figure out the phone's address and per-remote bytes
    frames = tshark(["-Y", "ip || ipv6", "-e", "frame.time_relative", "-e", "ip.src", "-e", "ip.dst",
                     "-e", "ipv6.src", "-e", "ipv6.dst", "-e", "frame.len",
                     "-e", "tcp.srcport", "-e", "tcp.dstport", "-e", "udp.srcport", "-e", "udp.dstport"],
                    a.tshark, a.pcap)
    addr_count = collections.Counter()
    parsed = []
    for f in frames:
        if len(f) < 10:
            continue
        t, s4, d4, s6, d6, ln, tsp, tdp, usp, udp = f
        src, dst = (first(s4) or first(s6)), (first(d4) or first(d6))
        if is_local_or_multicast(src) or is_local_or_multicast(dst):
            continue
        addr_count[src] += 1
        addr_count[dst] += 1
        proto = "tcp" if tsp else ("udp" if usp else "")
        sport = first(tsp) or first(usp)
        dport = first(tdp) or first(udp)
        parsed.append((float(t), src, dst, int(ln or 0), proto, sport, dport))
    if not parsed:
        print("No IP traffic in capture.")
        return
    phone = {addr_count.most_common(1)[0][0]}
    # a phone usually has one v4 and one v6 address; take the top v6 too if present
    for addr, _ in addr_count.most_common(4):
        if ":" in addr and not any(":" in p for p in phone):
            phone.add(addr)

    remote = collections.defaultdict(lambda: {"bytes": 0, "ports": collections.Counter(), "first": None})
    for t, src, dst, ln, proto, sport, dport in parsed:
        if src in phone and dst not in phone:
            r, port = dst, f"{proto}/{dport}"
        elif dst in phone and src not in phone:
            r, port = src, f"{proto}/{sport}"
        else:
            continue
        e = remote[r]
        e["bytes"] += ln
        e["ports"][port] += 1
        e["first"] = t if e["first"] is None else min(e["first"], t)

    # ---- DNS
    # port 53 only — mDNS (5353) answers would otherwise pollute provenance
    queries = tshark(["-Y", "dns.flags.response == 0 && (udp.port == 53 || tcp.port == 53)",
                      "-e", "frame.time_relative", "-e", "dns.qry.name", "-e", "ip.dst", "-e", "ipv6.dst"],
                     a.tshark, a.pcap)
    answers = tshark(["-Y", "dns.flags.response == 1 && (udp.port == 53 || tcp.port == 53)",
                      "-e", "frame.time_relative", "-e", "dns.qry.name", "-e", "dns.a", "-e", "dns.aaaa",
                      "-e", "dns.cname", "-e", "dns.flags.rcode"], a.tshark, a.pcap)
    ip_to_names = collections.defaultdict(set)
    resolvers = collections.Counter()
    meta_queries, meta_answers = [], []
    for q in queries:
        if len(q) < 4:
            continue
        t, name, d4, d6 = q
        resolvers[first(d4) or first(d6)] += 1
        if META.search(name):
            meta_queries.append((float(t), name, first(d4) or first(d6)))
    for r in answers:
        if len(r) < 6:
            continue
        t, name, a4, a6, cname, rcode = r
        name = first(name)
        ips = [x for x in (a4 + ";" + a6).split(";") if x]
        for ip in ips:
            if name:
                ip_to_names[ip].add(name)
        if META.search(name) or any(META.search(c) for c in cname.split(";")):
            meta_answers.append((float(t), name, rcode, ips, cname))

    # ---- SNI (TLS over TCP, and QUIC via decrypted Initial packets)
    snis = tshark(["-Y", "tls.handshake.extensions_server_name", "-e", "frame.time_relative", "-e", "ip.dst",
                   "-e", "ipv6.dst", "-e", "tcp.dstport", "-e", "udp.dstport",
                   "-e", "tls.handshake.extensions_server_name"], a.tshark, a.pcap)
    ip_to_sni = collections.defaultdict(set)
    sni_rows = []
    for s in snis:
        if len(s) < 6:
            continue
        t, d4, d6, tp, up, name = s
        ip = first(d4) or first(d6)
        for n in name.split(";"):
            if n:
                ip_to_sni[ip].add(n)
                sni_rows.append((float(t), n, ip, "quic" if up else "tls"))

    # ---- report
    print("=" * 78)
    print(f"Phone address(es): {', '.join(sorted(phone))}")
    print(f"Frames: {len(parsed)}   remote hosts: {len(remote)}   duration: {parsed[-1][0]:.0f}s")

    print("\n--- DNS resolvers used (plain port-53 queries) ---")
    for ip, n in resolvers.most_common():
        tag = "  <-- public resolver contacted directly (app-private DNS?)" if ip in KNOWN_RESOLVER_IPS else ""
        print(f"  {ip:40} {n:5} queries{tag}")
    if not resolvers:
        print("  (none — no plaintext DNS at all)")

    print(f"\n--- Meta-related DNS queries ({len(meta_queries)}) ---")
    for t, name, res in meta_queries[:40]:
        print(f"  {t:8.2f}s  {name:55} -> {res}")
    print(f"\n--- Meta-related DNS answers ({len(meta_answers)}) ---")
    for t, name, rcode, ips, cname in meta_answers[:40]:
        rc = {"0": "OK", "3": "NXDOMAIN"}.get(rcode, f"rcode={rcode}")
        extra = f"  cname={cname}" if cname else ""
        print(f"  {t:8.2f}s  {name:55} {rc:9} {', '.join(ips) or '-'}{extra}")

    print("\n--- Encrypted-DNS candidates (DoH/DoT) ---")
    doh = [(t, n, ip, k) for t, n, ip, k in sni_rows if DOH_SNI.search(n)]
    for t, n, ip, k in doh[:20]:
        print(f"  {t:8.2f}s  {k:4} SNI {n:40} -> {ip}")
    dot = [(ip, e) for ip, e in remote.items() if any(p.endswith("/853") for p in e["ports"])]
    for ip, e in dot:
        print(f"  DoT port 853 -> {ip}  ({e['bytes']} bytes)")
    resolver443 = [(ip, e) for ip, e in remote.items()
                   if ip in KNOWN_RESOLVER_IPS and any(p.endswith("/443") for p in e["ports"])]
    for ip, e in resolver443:
        print(f"  HTTPS to public resolver {ip}  ({e['bytes']} bytes)  <-- likely DoH")
    if not (doh or dot or resolver443):
        print("  (none found)")

    print("\n--- Meta-related SNI names seen (TLS + QUIC) ---")
    by_name = collections.defaultdict(set)
    for t, n, ip, k in sni_rows:
        if META.search(n):
            by_name[n].add(ip)
    for n in sorted(by_name):
        print(f"  {n:55} -> {', '.join(sorted(by_name[n]))}")
    if not by_name:
        print("  (none — no Meta hostnames in any ClientHello)")

    # ---- QUIC handshakes: long-header packets (first byte has 0x80 set) from
    # the phone. Meta's mvfst QUIC isn't recognized by Wireshark, so look at
    # raw UDP payload bytes. A host with video bytes but no long-header packet
    # was connected BEFORE the capture started (warm app / kept-alive session).
    phone_filter = " || ".join(f"ip.src=={p}" if ":" not in p else f"ipv6.src=={p}" for p in phone)
    handshakes = tshark(["-Y", f"udp.dstport==443 && ({phone_filter}) && (udp.payload[0] & 0x80)",
                         "-e", "frame.time_relative", "-e", "ip.dst", "-e", "ipv6.dst", "-e", "udp.payload"],
                        a.tshark, a.pcap)
    first_handshake = {}
    for h in handshakes:
        if len(h) < 4:
            continue
        t, d4, d6, payload = h
        ip = first(d4) or first(d6)
        payload = first(payload).replace(":", "")
        if ip not in first_handshake:
            first_handshake[ip] = (float(t), payload[2:10])  # QUIC version = bytes 1..4

    print(f"\n--- Top {a.top} remote hosts by bytes ---")
    socket.setdefaulttimeout(1.5)
    rows = sorted(remote.items(), key=lambda kv: kv[1]["bytes"], reverse=True)[: a.top]
    inband_bytes = named_bytes = 0
    for ip, e in rows:
        names = ip_to_names.get(ip, set())
        sni = ip_to_sni.get(ip, set())
        prov = "DNS: " + ", ".join(sorted(names)) if names else "NO DNS PROVENANCE IN CAPTURE"
        if not names:
            try:
                prov += f"  (rDNS {socket.gethostbyaddr(ip)[0]})"
            except Exception:
                pass
        is_meta = bool(META.search(" ".join(names | sni)) or META.search(prov))
        if is_meta and not names:
            inband_bytes += e["bytes"]
        if names:
            named_bytes += e["bytes"]
        ports = ", ".join(p for p, _ in e["ports"].most_common(3))
        print(f"  {ip:40} {e['bytes']/1024:9.0f} KB  first {e['first']:6.1f}s  [{ports}]")
        print(f"      {prov}")
        if sni:
            print(f"      SNI: {', '.join(sorted(sni))}")
        if any(p.startswith("udp/443") for p in e["ports"]):
            if ip in first_handshake:
                t, ver = first_handshake[ip]
                std = ver.lower() in ("00000001", "6b3343cf", "ff00001d")
                print(f"      QUIC handshake seen at {t:.1f}s, version 0x{ver}"
                      f"{' (standard)' if std else ' (custom — Wireshark cannot decrypt SNI)'}")
            else:
                print("      NO HANDSHAKE SEEN — connection existed before the capture started (warm app)")

    print("\n--- Reading the result ---")
    print(f"  bytes to hosts WITH a DNS answer in this capture:    {named_bytes/1024:9.0f} KB")
    print(f"  bytes to Meta hosts with NO DNS answer (in-band IP): {inband_bytes/1024:9.0f} KB")
    print("  * Meta CDN hosts with DNS provenance  -> DNS blocking can work (cold-cache issue).")
    print("  * Meta CDN hosts with no provenance   -> IPs delivered in-band; DNS blocking can't help.")
    print("  * fbcdn SNI present on those flows    -> SNI-based filtering in a full tunnel would catch them.")
    print("=" * 78)


if __name__ == "__main__":
    main()
