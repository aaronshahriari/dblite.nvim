#!/usr/bin/env python3
"""A throwaway Redis stand-in for trying dblite.nvim without installing Redis.

Development tool only — not shipped, not on the plugin's runtime path. It
speaks real RESP over a real socket and seeds data shaped to exercise every
rendering path dblite has: hashes, lists, sets, sorted sets, JSON, JSONL,
multi-line values, TTLs and deep key namespaces.

    python3 dev/mock-redis.py                 # port 6399, seeded
    python3 dev/mock-redis.py --port 7000
    python3 dev/mock-redis.py --keys 200000   # pad the keyspace, for perf work
    python3 dev/mock-redis.py --password s3cr3t

Then, in Neovim:

    :DbliteAddConn redis://127.0.0.1:6399/0
    :DbliteUseConn <name>

Where it differs from Redis, prefer Redis: `sudo pacman -S valkey` gives you
the real thing, and `valkey-server --port 6399` needs no root to run.

Deliberately faithful in two places that bit during development:
  - bulk payloads are read by their length prefix, not by line, so a value
    containing CRLF survives;
  - an integral sorted-set score renders as "847", not "847.0".
"""

import argparse
import fnmatch
import socketserver
import sys
import threading


# --- reply wrappers ---------------------------------------------------------

class Simple:
    __slots__ = ("s",)
    def __init__(self, s): self.s = s


class Err:
    __slots__ = ("s",)
    def __init__(self, s): self.s = s


def fmt_score(v):
    """Redis renders an integral score without a decimal point."""
    f = float(v)
    return str(int(f)) if f == int(f) else repr(f)


def encode(v):
    if v is None:
        return b"$-1\r\n"
    if isinstance(v, Simple):
        return f"+{v.s}\r\n".encode()
    if isinstance(v, Err):
        return f"-{v.s}\r\n".encode()
    if isinstance(v, bool):
        return b":1\r\n" if v else b":0\r\n"
    if isinstance(v, int):
        return f":{v}\r\n".encode()
    if isinstance(v, (list, tuple)):
        return f"*{len(v)}\r\n".encode() + b"".join(encode(x) for x in v)
    b = v.encode() if isinstance(v, str) else v
    return f"${len(b)}\r\n".encode() + b + b"\r\n"


# --- keyspace ---------------------------------------------------------------

def seed(filler=0):
    """A small keyspace covering every shape, optionally padded with filler."""
    data = {
        "user:1042": ("hash", {
            "name": "Aaron",
            "email": "a@example.com",
            "prefs": '{"theme":"dark","tz":"America/Chicago","notify":{"email":true,"sms":false}}',
        }),
        "user:1043": ("hash", {"name": "Bo", "email": "b@example.com",
                               "prefs": '{"theme":"light"}'}),
        "user:sessions:a83f": ("string", "tok-a83f"),
        "user:sessions:b91c": ("string", "tok-b91c"),
        "session:a83f-2291": ("string", "abc123"),
        # A lone JSON document: the case a one-cell grid truncates.
        "cfg:app": ("string", '{"debug":false,"retries":3,'
                              '"endpoints":{"primary":"eu-west","fallback":"us-east"}}'),
        # Newline-delimited JSON: one row per record.
        "events:jsonl": ("string", '{"id":1,"k":"a"}\n{"id":2,"k":"b"}\n{"id":3,"k":"c"}'),
        # Newlines in a plain value: what redis-cli round-trips badly.
        "note:multiline": ("string", "line one\nline two\nline three"),
        "queue:jobs": ("list", ["a", "b", "c", "d"]),
        "tags:active": ("set", ["alpha", "beta", "gamma"]),
        "leaderboard": ("zset", [("bob", 847.0), ("alice", 991.0)]),
        "standalone": ("string", "no namespace here"),
    }
    ttl = {"session:a83f-2291": 900, "user:sessions:a83f": 3600}
    for i in range(filler):
        data[f"filler:{i}"] = ("string", f"v{i}")
    return data, ttl


class Keyspace:
    def __init__(self, filler=0):
        self.data, self.ttl = seed(filler)
        self.lock = threading.Lock()

    def size_of(self, key):
        kind, val = self.data[key]
        if kind == "string":
            return len(val.encode())
        return len(val)


# --- server -----------------------------------------------------------------

class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.setsockopt(socket_opt_level(), socket_opt_nodelay(), 1)
        while True:
            args = self.read_command()
            if args is None:
                return
            if not args:
                continue
            reply = self.dispatch(args)
            if reply is QUIT:
                self.wfile.write(encode(Simple("OK")))
                self.wfile.flush()
                return
            self.wfile.write(encode(reply))
            self.wfile.flush()

    def read_command(self):
        line = self.rfile.readline()
        if not line:
            return None
        if not line.startswith(b"*"):
            return None
        args = []
        for _ in range(int(line[1:])):
            header = self.rfile.readline()          # $<len>
            if not header:
                return None
            # Length-prefixed: a payload may itself contain CRLF.
            n = int(header[1:])
            payload = self.rfile.read(n)
            self.rfile.read(2)                      # trailing CRLF
            args.append(payload.decode("utf-8", "replace"))
        return args

    def dispatch(self, a):
        ks = self.server.keyspace
        c = a[0].upper()
        data, ttl = ks.data, ks.ttl

        if c == "QUIT":
            return QUIT
        if c == "PING":
            return Simple("PONG")
        if c == "SELECT":
            return Simple("OK")
        if c == "AUTH":
            want = self.server.password
            got = a[-1]
            if want is None:
                return Err("ERR Client sent AUTH, but no password is set")
            return Simple("OK") if got == want else Err("WRONGPASS invalid username-password pair")
        if c == "DBSIZE":
            return len(data)
        if c == "INFO":
            return ("# Server\r\nredis_version:7.2.4-mock\r\nuptime_in_seconds:1234\r\n"
                    "\r\n# Clients\r\nconnected_clients:1\r\n"
                    "\r\n# Replication\r\nrole:master\r\nconnected_slaves:0\r\n"
                    f"\r\n# Keyspace\r\ndb0:keys={len(data)},expires={len(ttl)}\r\n")
        if c == "COMMAND":
            return [[n, arity, flags] for n, arity, flags in COMMANDS]
        if c == "FLUSHDB":
            with ks.lock:
                data.clear(); ttl.clear()
            return Simple("OK")

        if c == "SCAN":
            return self.scan(a)

        # --- single-key reads ---
        if c == "EXISTS":
            return 1 if a[1] in data else 0
        if c == "TYPE":
            return Simple(data[a[1]][0] if a[1] in data else "none")
        if c == "TTL":
            if a[1] not in data:
                return -2
            return ttl.get(a[1], -1)
        if c in ("STRLEN", "LLEN", "SCARD", "ZCARD", "HLEN", "XLEN"):
            return ks.size_of(a[1]) if a[1] in data else 0
        if c == "GET":
            if a[1] not in data:
                return None
            kind, val = data[a[1]]
            if kind != "string":
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            return val
        if c == "HGETALL":
            e = data.get(a[1])
            if not e or e[0] != "hash":
                return []
            out = []
            for k, v in e[1].items():
                out += [k, v]
            return out
        if c == "HKEYS":
            e = data.get(a[1])
            return list(e[1].keys()) if e and e[0] == "hash" else []
        if c == "HGET":
            e = data.get(a[1])
            if not e or e[0] != "hash":
                return None
            return e[1].get(a[2])
        if c == "LRANGE":
            e = data.get(a[1])
            return list(e[1]) if e and e[0] == "list" else []
        if c == "SMEMBERS":
            e = data.get(a[1])
            return list(e[1]) if e and e[0] == "set" else []
        if c in ("ZRANGE", "ZRANGEBYSCORE"):
            e = data.get(a[1])
            if not e or e[0] != "zset":
                return []
            with_scores = any(x.upper() == "WITHSCORES" for x in a)
            out = []
            for m, s in sorted(e[1], key=lambda kv: kv[1]):
                out.append(m)
                if with_scores:
                    out.append(fmt_score(s))
            return out
        if c == "ZSCORE":
            e = data.get(a[1])
            if not e or e[0] != "zset":
                return None
            for m, s in e[1]:
                if m == a[2]:
                    return fmt_score(s)
            return None

        # --- writes ---
        with ks.lock:
            if c == "SET":
                data[a[1]] = ("string", a[2]); return Simple("OK")
            if c == "DEL":
                n = 0
                for k in a[1:]:
                    if data.pop(k, None) is not None:
                        ttl.pop(k, None); n += 1
                return n
            if c == "EXPIRE":
                if a[1] not in data:
                    return 0
                ttl[a[1]] = int(a[2]); return 1
            if c == "PERSIST":
                return 1 if ttl.pop(a[1], None) is not None else 0
            if c in ("HSET", "HMSET"):
                e = data.get(a[1], ("hash", {}))
                if e[0] != "hash":
                    return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
                for i in range(2, len(a) - 1, 2):
                    e[1][a[i]] = a[i + 1]
                data[a[1]] = ("hash", e[1])
                return len(a[2:]) // 2
            if c == "HDEL":
                e = data.get(a[1])
                if not e or e[0] != "hash":
                    return 0
                return sum(1 for f in a[2:] if e[1].pop(f, None) is not None)
            if c in ("RPUSH", "LPUSH"):
                e = data.get(a[1], ("list", []))
                if e[0] != "list":
                    return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
                items = list(a[2:])
                if c == "RPUSH":
                    e[1].extend(items)
                else:
                    e[1][:0] = items[::-1]
                data[a[1]] = ("list", e[1])
                return len(e[1])
            if c == "SADD":
                e = data.get(a[1], ("set", []))
                if e[0] != "set":
                    return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
                added = 0
                for m in a[2:]:
                    if m not in e[1]:
                        e[1].append(m); added += 1
                data[a[1]] = ("set", e[1])
                return added
            if c == "ZADD":
                e = data.get(a[1], ("zset", []))
                if e[0] != "zset":
                    return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
                members = dict(e[1])
                for i in range(2, len(a) - 1, 2):
                    members[a[i + 1]] = float(a[i])
                data[a[1]] = ("zset", sorted(members.items(), key=lambda kv: kv[1]))
                return len(a[2:]) // 2

        return Err(f"ERR unknown command '{a[0]}'")

    def scan(self, a):
        """Cursor-based SCAN. MATCH is applied after the batch is taken, as
        Redis does, so COUNT bounds keys examined rather than keys returned."""
        ks = self.server.keyspace
        cursor = int(a[1])
        match, count = "*", 10
        for i in range(2, len(a) - 1):
            if a[i].upper() == "MATCH":
                match = a[i + 1]
            elif a[i].upper() == "COUNT":
                count = int(a[i + 1])

        keys = list(ks.data)
        end = min(cursor + count, len(keys))
        batch = [k for k in keys[cursor:end] if fnmatch.fnmatchcase(k, match)]
        nxt = 0 if end >= len(keys) else end
        return [str(nxt), batch]


QUIT = object()

COMMANDS = [
    ("get", 2, ["readonly", "fast"]),      ("set", -3, ["write", "denyoom"]),
    ("del", -2, ["write"]),                ("exists", -2, ["readonly", "fast"]),
    ("expire", -3, ["write", "fast"]),     ("persist", 2, ["write", "fast"]),
    ("ttl", 2, ["readonly", "fast"]),      ("type", 2, ["readonly", "fast"]),
    ("strlen", 2, ["readonly", "fast"]),   ("keys", 2, ["readonly"]),
    ("scan", -2, ["readonly"]),            ("dbsize", 1, ["readonly", "fast"]),
    ("hget", 3, ["readonly", "fast"]),     ("hset", -4, ["write", "denyoom"]),
    ("hgetall", 2, ["readonly"]),          ("hkeys", 2, ["readonly"]),
    ("hdel", -3, ["write", "fast"]),       ("hlen", 2, ["readonly", "fast"]),
    ("lrange", 4, ["readonly"]),           ("rpush", -3, ["write", "denyoom"]),
    ("lpush", -3, ["write", "denyoom"]),   ("llen", 2, ["readonly", "fast"]),
    ("sadd", -3, ["write", "denyoom"]),    ("smembers", 2, ["readonly"]),
    ("scard", 2, ["readonly", "fast"]),    ("zadd", -4, ["write", "denyoom"]),
    ("zrange", -4, ["readonly"]),          ("zscore", 3, ["readonly", "fast"]),
    ("zcard", 2, ["readonly", "fast"]),    ("info", -1, ["loading", "stale"]),
    ("command", -1, ["loading", "stale"]), ("flushdb", -1, ["write"]),
    ("ping", -1, ["fast"]),                ("select", 2, ["loading", "fast"]),
]


def socket_opt_level():
    import socket
    return socket.IPPROTO_TCP


def socket_opt_nodelay():
    import socket
    return socket.TCP_NODELAY


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    ap = argparse.ArgumentParser(description="Redis stand-in for dblite.nvim development")
    ap.add_argument("--port", type=int, default=6399)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--password", default=None, help="require AUTH with this password")
    ap.add_argument("--keys", type=int, default=0,
                    help="pad the keyspace with N filler:<n> keys, for performance testing")
    args = ap.parse_args()

    ks = Keyspace(args.keys)
    srv = Server((args.host, args.port), Handler)
    srv.keyspace = ks
    srv.password = args.password

    scheme = "redis://"
    auth = f":{args.password}@" if args.password else ""
    print(f"mock-redis listening on {args.host}:{args.port}  ({len(ks.data)} keys)", flush=True)
    print(f"  :DbliteAddConn {scheme}{auth}{args.host}:{args.port}/0", flush=True)
    print("  Ctrl-C to stop", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")
        return 0


if __name__ == "__main__":
    sys.exit(main())
