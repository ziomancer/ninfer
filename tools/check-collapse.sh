#!/usr/bin/env bash
# Quantization-collapse watchdog for the local NInfer engine (nvfp4 weights +
# INT8 group-64 KV). Watches for the failure modes that matter: the model getting
# stuck in cycles, or degrading into junk.
#
# IMPORTANT LIMITATION: NInfer's request log records METADATA ONLY -- it has no response
# text (verified against a live schema 10 record). So this cannot detect
# repetition directly. It infers looping from the strongest available proxy: requests
# that run to their full output budget. Nothing here inspects a single token of output.
#
# Fields used (all confirmed present in a live request_done record):
#   result/finish_reason, result/completion_tokens, request/requested_output_tokens
#   speculative/{accepted_tokens,drafted_tokens,fallback_steps,rounds}
#
# Usage: ./check-collapse.sh [n_recent]      (default: last 500 request_done records)
set -uo pipefail
N=${1:-500}
LOG="$(cd "$(dirname "$0")/.." && pwd)/logs/requests.jsonl"

if [ ! -f "$LOG" ]; then
  echo "No request log at $LOG"
  echo "It appears once the engine serves a request with --request-log-jsonl active."
  exit 0
fi
echo "log: $LOG  size=$(du -h "$LOG" | cut -f1)  (NInfer never rotates this -- prune manually)"

N=$N python - "$LOG" <<'PY'
import json,os,sys,collections
path=sys.argv[1]; N=int(os.environ["N"])
rd=[]
for line in open(path,encoding="utf-8"):
    line=line.strip()
    if not line: continue
    try: r=json.loads(line)
    except Exception: continue
    if r.get("event")=="request_done": rd.append(r)
rd=rd[-N:]
if not rd:
    print("no completed requests in the log yet"); sys.exit(0)
print(f"window: {len(rd)} completed requests\n")

WARN=[]

# -- 1. Output-budget exhaustion -- the loop proxy --
fin=collections.Counter(r.get("result",{}).get("finish_reason","?") for r in rd)
print("finish reasons:")
tot=sum(fin.values())
for k,v in fin.most_common():
    print(f"  {k:16} {v:5}  {100*v/tot:5.1f}%")
exhausted=sum(v for k,v in fin.items() if k in ("output_limit","length"))
if tot and exhausted/tot > 0.15:
    WARN.append(f"{100*exhausted/tot:.0f}% of requests ran to their full output budget "
                f"(>15%). A model stuck in a cycle exhausts its budget -- inspect those responses.")
print()

# -- 2. Long generations that also hit the ceiling --
maxed=[r for r in rd
       if r.get("result",{}).get("finish_reason") in ("output_limit","length")
       and r.get("result",{}).get("completion_tokens",0) >= 2000]
if maxed:
    WARN.append(f"{len(maxed)} request(s) generated >=2000 tokens AND hit the ceiling -- "
                f"the clearest loop signature available without response text.")
    for r in maxed[:3]:
        print(f"  long+maxed: completion={r['result']['completion_tokens']} "
              f"requested={r.get('request',{}).get('requested_output_tokens')} "
              f"ts={r.get('timestamp_unix_ms')}")
    print()

# -- 3. MTP acceptance -- an incoherent model surprises its own drafter --
acc=sum(r.get("speculative",{}).get("accepted_tokens",0) or 0 for r in rd)
dra=sum(r.get("speculative",{}).get("drafted_tokens",0) or 0 for r in rd)
fb =sum(r.get("speculative",{}).get("fallback_steps",0) or 0 for r in rd)
if dra:
    rate=100*acc/dra
    print(f"MTP acceptance: {rate:.1f}%   (baseline on this host: ~48% for nvfp4/dt=4)")
    print(f"fallback steps: {fb}")
    if rate < 30:
        WARN.append(f"MTP acceptance {rate:.1f}% is well below the ~48% baseline. The drafter "
                    f"predicts the model poorly -- consistent with degraded generation.")
    print()

# -- 4. Throughput drift -- the LM Studio failure mode, restated --
rates=[]
for r in rd:
    t=r.get("timings_seconds",{}).get("decode",0) or 0
    c=r.get("result",{}).get("completion_tokens",0) or 0
    if t>0.5 and c>50: rates.append(c/t)
if len(rates)>=10:
    half=len(rates)//2
    early=sum(rates[:half])/half; late=sum(rates[half:])/(len(rates)-half)
    print(f"decode tok/s: first half {early:.1f}  second half {late:.1f}")
    if early>0 and late < early*0.75:
        WARN.append(f"decode fell {100*(1-late/early):.0f}% across the window "
                    f"({early:.0f} -> {late:.0f} tok/s). This is the shape of the LM Studio "
                    f"regression; check nvidia-smi for a new VRAM tenant.")
    print()

print("="*68)
if WARN:
    print("FLAGGED:")
    for w in WARN: print(f"  ! {w}")
else:
    print("No collapse signal in this window.")
print()
print("This checks for specific SYMPTOMS. It does not certify output quality --")
print("the log has no response text, so junk that terminates normally is invisible here.")
PY
