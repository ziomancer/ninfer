#!/usr/bin/env bash
# Decode-throughput harness for the local NInfer engine.
#
# Reads the decode rate from NInfer's OWN request log rather than timing the HTTP round
# trip. Decode is (completion_tokens - 1) / timings_seconds.decode: prefill emits the
# first token, the rest come from decode. Wall-clock timing would fold in prefill and
# TTFT and understate decode. The formula is the same on every engine version, so two
# runs of this script are comparable; the human log line's rate is not.
#
# Thinking is disabled with reasoning_effort:"none" — NInfer rejects
# chat_template_kwargs.enable_thinking outright (it is strict about unknown fields).
# Without this, reasoning tokens dominate short generations and the variance swamps
# the signal we are trying to measure.
#
# Usage: bench/bench.sh [samples] [max_tokens]      (from any directory)
set -uo pipefail
SAMPLES=${1:-5}
MAXTOK=${2:-512}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$ROOT/logs/requests.jsonl"
envval() { sed -n "s/^$1=//p" "$ROOT/.env" | tr -d '\r' | head -n 1; }
KEY=$(envval NINFER_API_KEY)
PORT=${NINFER_PORT:-$(envval NINFER_PORT)}
PORT=${PORT:-3400}

PROMPT="Write a detailed technical explanation of how a B-tree index works in a relational database, covering node structure, splits, and range scans."

echo "samples=$SAMPLES max_tokens=$MAXTOK port=$PORT"

# Count existing lines so we can slice off exactly the new records.
before=$(wc -l < "$LOG")

for i in $(seq 1 "$SAMPLES"); do
  code=$(curl -s -m 300 -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d "{\"model\":\"qwen/qwen3.8-27b\",
         \"messages\":[{\"role\":\"user\",\"content\":\"$PROMPT\"}],
         \"max_tokens\":$MAXTOK,
         \"reasoning_effort\":\"none\"}" \
    "http://127.0.0.1:$PORT/v1/chat/completions")
  printf "  sample %d/%d http=%s\n" "$i" "$SAMPLES" "$code"
done

BEFORE=$before python - "$LOG" <<'PY'
import json,math,os,sys
rates=[]; acc=dra=0
with open(sys.argv[1],encoding="utf-8") as f:
    for n,line in enumerate(f):
        if n<int(os.environ["BEFORE"]) or not line.strip(): continue
        r=json.loads(line)
        if r.get("event")!="request_done": continue
        gen=r["result"]["completion_tokens"]; t=r["timings_seconds"]["decode"]
        if gen<2 or t<=0: continue
        rates.append((gen-1)/t)
        s=r.get("speculative") or {}
        acc+=s.get("accepted_tokens",0) or 0; dra+=s.get("drafted_tokens",0) or 0
        print(f"  gen={gen} decode_s={t:.3f} rate={rates[-1]:.1f} tok/s")
if not rates:
    print("\nno samples"); sys.exit(1)
m=sum(rates)/len(rates)
sd=math.sqrt(sum((x-m)**2 for x in rates)/(len(rates)-1)) if len(rates)>1 else 0
print(f"\nmean={m:.1f} tok/s  sd={sd:.1f}  n={len(rates)}")
if dra: print(f"MTP acceptance={100*acc/dra:.1f}%")
PY
