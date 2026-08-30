#!/usr/bin/env bash
# Decode-throughput harness for the local NInfer engine.
#
# Reads the decode rate from NInfer's OWN per-request log line rather than timing the
# HTTP round trip. The server reports committed-token decode rate excluding prefill,
# which is what the published benchmarks in docs/performance.md measure; wall-clock
# timing would fold in prefill and TTFT and understate decode.
#
# Thinking is disabled with reasoning_effort:"none" — NInfer rejects
# chat_template_kwargs.enable_thinking outright (it is strict about unknown fields).
# Without this, reasoning tokens dominate short generations and the variance swamps
# the signal we are trying to measure.
#
# Usage: ./bench.sh [samples] [max_tokens]
set -uo pipefail
SAMPLES=${1:-5}
MAXTOK=${2:-512}
PORT=${NINFER_PORT:-3400}
KEY=$(sed -n 's/^NINFER_API_KEY=//p' ../.env | tr -d '\r')

PROMPT="Write a detailed technical explanation of how a B-tree index works in a relational database, covering node structure, splits, and range scans."

echo "samples=$SAMPLES max_tokens=$MAXTOK port=$PORT"

# Count existing completed-request lines so we can slice off exactly the new ones.
# `docker logs --since` proved unreliable here (local-vs-UTC interpretation), and a
# fixed --tail would silently mix in earlier requests.
before=$(docker logs vigil-chat-model 2>&1 | grep -c "] done finish=")

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

NEW=$(docker logs vigil-chat-model 2>&1 | grep "] done finish=" | tail -n +$((before+1)))

echo "--- NInfer-reported per-request ---"
printf '%s\n' "$NEW" | grep -o 'gen=[0-9]*.*' | sed 's/cache=[0-9]* //; s/reuse=[a-z_]* //'

printf '%s\n' "$NEW" | grep -o 'decode=[0-9.]*' | sed 's/decode=//' \
  | awk '{s+=$1; a[NR]=$1} END {
      if(NR==0){print "\nno samples"; exit}
      m=s/NR; v=0; for(i=1;i<=NR;i++) v+=(a[i]-m)^2;
      printf "\nmean=%.1f tok/s  sd=%.1f  n=%d\n", m, (NR>1? sqrt(v/(NR-1)) : 0), NR}'
