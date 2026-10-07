"""Stage 10's kill-switch test (docs/RESTORE.md Stage 10, C-21).

linux/stages/10-vps.sh kill-switch runs this inside the Brave/Jina
gateway's container, which shares gluetun's network namespace, with
'docker exec -i ... python -'. It prints only 'FACT ks_<name> <word>',
'STEP <text>' and 'FAIL <text>' lines: never an address, a page or an
answer.

  1. Before: the tunnel works (a direct TCP connection and a DNS lookup
     leave through it), so a failure later means something.
  2. It stops the tunnel through gluetun's control server.
  3. Everything must fail closed while it is stopped: the gateway's
     /search and /read-url, Jina Reader, SearXNG, gluetun's HTTP proxy
     and its relay, a direct TCP connection over IPv4 and over IPv6, a
     lookup of a name nobody has asked for before, and a plain DNS query
     to two public resolvers. Each search and page carries a word made up
     for this run, so no cache can answer it.
  4. The tunnel must still be stopped when the probes end; if gluetun
     started it again on its own, the result would mean nothing.
  5. In 'finally' it starts the tunnel again, then waits for a direct
     connection and one /search to work.

The PC (windows/stages/10-rehearsal.ps1) decides pass or fail from the
facts; this exits 1 only when it could not run the test.
"""

import json
import os
import socket
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CONTROL = "http://127.0.0.1:8000/v1/vpn/status"
GATEWAY = "http://127.0.0.1:13100"
READER = "http://127.0.0.1:3000/"
SEARXNG = "http://127.0.0.1:8080/search?format=json&q="
TCP4 = ("1.1.1.1", 443)
TCP6 = ("2606:4700:4700::1111", 443)
RESOLVERS = ("9.9.9.9", "1.1.1.1")


def fact(name, value):
    print(f"FACT ks_{name} {value}", flush=True)


def step(text):
    print(f"STEP {text}", flush=True)


def control(status=None):
    """The tunnel's status, after setting it when status is given."""
    if status:
        body = json.dumps({"status": status}).encode()
        request = urllib.request.Request(CONTROL, data=body, headers={"Content-Type": "application/json"}, method="PUT")
    else:
        request = urllib.request.Request(CONTROL)
    with urllib.request.urlopen(request, timeout=10) as response:
        answer = json.load(response)
    return str(answer.get("status", "")) if isinstance(answer, dict) else ""


def gateway(path, body, timeout):
    """The gateway's 'status' word, or transport_error when it did not answer."""
    request = urllib.request.Request(GATEWAY + path, data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            answer = json.load(response)
    except (OSError, ValueError):
        return "transport_error"
    return str(answer.get("status", "unknown")) if isinstance(answer, dict) else "unknown"


def tcp(family, address, timeout=8):
    try:
        with socket.socket(family, socket.SOCK_STREAM) as s:
            s.settimeout(timeout)
            s.connect(address)
        return "connected"
    except OSError:
        return "blocked"


def lookup(name):
    try:
        socket.getaddrinfo(name, 443, proto=socket.IPPROTO_TCP)
        return "resolved"
    except OSError:
        return "no-address"


def plain_dns(server, timeout=5):
    """A plain DNS question for example.com to a public resolver."""
    question = struct.pack(">HHHHHH", 0x4352, 0x0100, 1, 0, 0, 0)
    question += b"".join(bytes([len(p)]) + p.encode() for p in ("example", "com")) + b"\x00"
    question += struct.pack(">HH", 1, 1)
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.settimeout(timeout)
            s.sendto(question, (server, 53))
            s.recvfrom(512)
        return "answered"
    except OSError:
        return "no-answer"


def proxy(port, timeout=15):
    """Whether the HTTP proxy on this port opens a tunnel to example.com."""
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=timeout) as s:
            s.sendall(b"CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
            line = s.recv(64).split(b"\r\n", 1)[0]
        return "connected" if line.split(b" ")[1:2] == [b"200"] else "blocked"
    except (OSError, IndexError):
        return "blocked"


def reader(url, timeout=40):
    try:
        with urllib.request.urlopen(READER + url, timeout=timeout) as response:
            return "read" if b"Example Domain" in response.read(200000) else "blocked"
    except (OSError, ValueError):
        return "blocked"


def searxng(query, timeout=30):
    try:
        with urllib.request.urlopen(SEARXNG + urllib.parse.quote_plus(query), timeout=timeout) as response:
            answer = json.load(response)
    except (OSError, ValueError):
        return "none"
    return "results" if isinstance(answer, dict) and answer.get("results") else "none"


def main():
    before = {"tcp4": tcp(socket.AF_INET, TCP4), "dns": lookup("example.com")}
    for name, value in before.items():
        fact(f"before_{name}", value)
    if before["tcp4"] != "connected" or before["dns"] != "resolved":
        print("FAIL the tunnel does not work before the test, so a failure would prove nothing; nothing was changed", flush=True)
        return 1
    try:
        status = control()
    except (OSError, ValueError) as exc:
        print(f"FAIL gluetun's control server did not answer ({type(exc).__name__}); nothing was changed", flush=True)
        return 1
    if status != "running":
        print(f"FAIL the tunnel is '{status or 'unknown'}', not running; nothing was changed", flush=True)
        return 1

    try:
        try:
            control("stopped")
        except (OSError, ValueError) as exc:
            print(f"FAIL gluetun's control server would not stop the tunnel ({type(exc).__name__})", flush=True)
            return 1
        time.sleep(3)
        step("tunnel stopped through gluetun's control server")
        word = f"cria{os.urandom(4).hex()}"
        page = f"https://example.com/?{word}"
        fact("search", gateway("/search", {"query": f"kill switch {word}", "count": 1}, 50))
        fact("read", gateway("/read-url", {"url": page, "options": {"engine": "browser", "timeout": 8}}, 35))
        fact("reader", reader(page))
        fact("searxng", searxng(f"kill switch {word}"))
        fact("proxy_8888", proxy(8888))
        fact("proxy_8889", proxy(8889))
        fact("tcp4", tcp(socket.AF_INET, TCP4))
        fact("tcp6", tcp(socket.AF_INET6, TCP6))
        fact("dns_new_name", lookup(f"{word}.example.com"))
        for i, server in enumerate(RESOLVERS, 1):
            fact(f"dns_plain_{i}", plain_dns(server))
        try:
            fact("still_stopped", "yes" if control() == "stopped" else "no")
        except (OSError, ValueError):
            fact("still_stopped", "unknown")
    finally:
        try:
            control("running")
        except (OSError, ValueError):
            pass
        step("tunnel started again")

    recovered = "no"
    for _ in range(24):
        time.sleep(5)
        if tcp(socket.AF_INET, TCP4, timeout=5) == "connected" and gateway("/search", {"query": "UK Parliament", "count": 1}, 50) == "ok":
            recovered = "yes"
            break
    fact("recovered", recovered)
    return 0


if __name__ == "__main__":
    sys.exit(main())
