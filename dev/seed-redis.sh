#!/usr/bin/env bash
# Seeds a local Redis/Valkey with data shaped to exercise every dblite
# rendering path. Development tool only.
#
#   dev/seed-redis.sh                 # port 6399
#   dev/seed-redis.sh 6379            # another port
#   BULK=200000 dev/seed-redis.sh     # pad the keyspace, for scan-latency work
#
# Everything lands under demo: and (optionally) filler:, so it is easy to drop:
#   valkey-cli -p 6399 --scan --pattern 'demo:*' | xargs -r valkey-cli -p 6399 DEL
set -euo pipefail

PORT="${1:-6399}"
CLI=$(command -v valkey-cli || command -v redis-cli) || {
  echo "need valkey-cli or redis-cli on PATH" >&2; exit 1; }
BULK="${BULK:-0}"

r() { "$CLI" -p "$PORT" "$@" > /dev/null; }

"$CLI" -p "$PORT" PING > /dev/null || { echo "no server on port $PORT" >&2; exit 1; }

# --- hashes: field/value, one field holding JSON ---------------------------
r HSET demo:user:1042 name Aaron email a@example.com \
      prefs '{"theme":"dark","tz":"America/Chicago","notify":{"email":true,"sms":false}}'
r HSET demo:user:1043 name Bo email b@example.com prefs '{"theme":"light"}'

# --- deep namespaces: progressive completion ------------------------------
r SET demo:user:sessions:a83f tok-a83f
r SET demo:user:sessions:b91c tok-b91c
r SET demo:user:profile:1042 '{"bio":"hi"}'

# --- a lone JSON document: the case a one-cell grid truncates -------------
r SET demo:cfg:app '{"debug":false,"retries":3,"endpoints":{"primary":"eu-west","fallback":"us-east"}}'

# --- JSONL: one row per record -------------------------------------------
r SET demo:events:jsonl '{"id":1,"k":"a"}
{"id":2,"k":"b"}
{"id":3,"k":"c"}'

# --- newlines and spaces in plain values: the redis-cli round-trip bugs ---
r SET demo:note:multiline 'line one
line two
line three'
r SET demo:note:spaced 'a value with spaces, and a comma'

# --- JSON documents ------------------------------------------------------
# RedisJSON's JSON.GET returns a bulk string of JSON, which is the same reply
# shape as GET on a string holding JSON. Without the module loaded these keys
# exercise the identical rendering path, so `GET demo:json:order` here behaves
# as `JSON.GET order:1234` does on a server that has it.
r SET demo:json:order '{"id":4821,"customer":"team-x","status":"shipped","total":129.95,"items":[{"sku":"WIDGET-1","qty":2,"price":49.99},{"sku":"GIZMO-7","qty":1,"price":29.97}],"address":{"line1":"1 Example Way","city":"Austin","region":"TX","postal":"78701"},"meta":{"created":"2026-01-04T10:22:00Z","updated":"2026-02-11T08:03:12Z","flags":{"gift":false,"expedited":true}}}'

# Deeply nested: shows the indenting actually doing something.
r SET demo:json:deep '{"a":{"b":{"c":{"d":{"e":{"f":"bottom","g":[1,2,{"h":true}]}}}}}}'

# A top-level array, which is what `JSON.GET key $` returns.
r SET demo:json:path '[{"name":"widget","qty":2}]'

# A single scalar wrapped in an array: `JSON.GET key $.count`.
r SET demo:json:scalar '[42]'

# An empty object and an empty array — both still documents.
r SET demo:json:empty '{}'

# Not JSON, despite the braces: must stay a grid cell, not be mis-detected.
r SET demo:json:broken '{"a": 1, "b":'

# --- collections ----------------------------------------------------------
r RPUSH demo:queue:jobs a b c d
r SADD demo:tags:active alpha beta gamma
r ZADD demo:leaderboard 991 alice 847 bob 1203 carol
r ZADD demo:leaderboard 12.5 'member with spaces'

# --- a TTL, so the ttl column is not always blank -------------------------
r SET demo:session:a83f-2291 abc123
r EXPIRE demo:session:a83f-2291 900

# --- no namespace at all --------------------------------------------------
r SET demo_standalone 'no separator here'

# --- optional bulk padding ------------------------------------------------
if [ "$BULK" -gt 0 ]; then
  echo "padding with $BULK filler keys..."
  # One pipelined stream: far faster than a process per key.
  { for i in $(seq 1 "$BULK"); do printf 'SET filler:%s v%s\r\n' "$i" "$i"; done; } \
    | "$CLI" -p "$PORT" --pipe > /dev/null 2>&1
fi

echo "seeded on port $PORT — DBSIZE: $("$CLI" -p "$PORT" DBSIZE)"
echo
echo "In Neovim:"
echo "  :DbliteAddConn redis://127.0.0.1:$PORT/0"
