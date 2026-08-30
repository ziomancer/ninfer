# NInfer decode throughput on this host

Method: `bench.sh` — 512-token generations, thinking off (`reasoning_effort:"none"`),
decode rate read from NInfer's own per-request log line (committed tokens, excludes
prefill), which is the same quantity `docs/performance.md` reports. Qwen3.8-27B
**groupwise-int**, single stream, RTX 5090 32 GiB, `--max-context 32768`,
`--max-concurrency 2`, `--lm-head-draft` on for every MTP row.

## Speculative decoding sweep

| Config | Decode tok/s | sd | n | MTP acceptance | tok/round |
|---|---:|---:|---:|---:|---:|
| MTP off (baseline) | 87.4 | 0.1 | 5 | — | — |
| `--spec mtp --draft-tokens 2` | 172.9 | 7.1 | 5 | ~68% | 2.36 |
| `--spec mtp --draft-tokens 3` | 169.7 | 11.1 | 5 | ~54% | 2.62 |
| `--spec mtp --draft-tokens 4` | 175.6 | 7.8 | 5 | ~51% | 3.02 |
| `--spec mtp --draft-tokens 4` | **169.5** | 9.9 | **10** | ~50% | 3.00 |
| `--spec mtp --draft-tokens 5` | 158.2 | 3.8 | 5 | ~41% | 3.02 |
| `--draft-tokens 4 --kv-dtype int8` | 167.9 | 8.6 | 10 | ~50% | 3.00 |

**Headline: MTP roughly doubles decode — 87.4 → ~170 tok/s (1.94×).**

Read the two `draft-tokens 4` rows together: 5 samples said 175.6, 10 samples said 169.5.
The 5-sample figure was optimism, and the same caution applies to every 5-sample row here.
Treat 2/3/4 as **indistinguishable at ~170**; only `5` separates, and it separates downward.

Notes:

- Acceptance falls monotonically as the draft window grows (68% → 51% → 41%) while
  `tok/round` plateaus at ~3.0 from dt=4. At dt=5 the engine drafts no further ahead but
  wastes more of it, so throughput drops — that is why 5 is strictly worse, not just flat.
- `--draft-tokens 2` reaches the **published 68% acceptance** and still only makes 172.9
  against the published 185.8. So the residual gap is **not** acceptance — it is the
  artifact. The published number is Qwen3.**6**-27B; the Qwen3.8-27B groupwise-int profile
  is explicitly outside NInfer's published campaign (`docs/performance.md:29`).
- `--kv-dtype int8` is a **VRAM lever, not a speed lever**: throughput unchanged within
  noise, KV runtime 5.19 → 3.13 GiB, free VRAM 6.7 → 8.9 GB. Left at bf16 — no reason to
  take quantized-KV quality risk for zero throughput. Switch only if VRAM is needed.
- MTP residency costs ~1.07 GiB (proposal head + CUDA graphs 24 → 164 MiB).

## VRAM, final config

| | |
|---|---|
| Weights | 15.92 GiB |
| KV cache (65,536 tokens, pre-allocated) | 5.19 GiB |
| MTP + graphs | ~1.07 GiB |
| Total used / free | 25,467 MiB / 6,721 MiB |

KV is claimed at startup (`pages=1024/1024`), so free VRAM does not shrink under load —
verified stable across 24.8k-token prompts.

## The road to 200 tok/s

Current: **~170 tok/s single-stream.** The engine-side knobs are now exhausted; 200 needs
another +18%.

| Lever | Expected | Cost | Verdict |
|---|---|---|---|
| `draft-tokens` tuning | — | none | **Done.** ~170 is the plateau; no setting reaches 200 |
| `--kv-dtype int8` | +0% | quality risk | **No.** Measured zero gain |
| **nvfp4 artifact** | ~185 (+9%) | 20.02 GiB download, +3 GiB VRAM | **Best remaining single-stream option.** Published Qwen3.6-27B: nvfp4 202.4 vs groupwise-int 185.8 at C=1 |
| Concurrency C=2 | **247 aggregate** | none — already configured | **Free, but aggregate only.** Does not speed up one conversation |
| MoE model (35B-A3B) | **593** at C=1 | different model | Only if a model change is acceptable — 3B active params, an order of magnitude cheaper per token |

**Honest conclusion: 200 tok/s single-stream is not reachable for a dense 27B on one 5090.**
NInfer's own best published single-stream figure for a 27B is 202.4 (nvfp4, Qwen3.6), and
that is the ceiling of the measured space — we would be chasing its last 9% with a 20 GiB
re-download for an estimated ~185.

Two framings that *do* reach 200+:

1. **Aggregate, not single-stream.** `--max-concurrency 2` is already set, and the
   published groupwise-int figure at C=2 is 247 tok/s aggregate (nvfp4: 399.7). If the goal
   is throughput across parallel agents rather than one chat feeling faster, **you are
   already past 200** and nothing needs changing.
2. **Change the model class.** Qwen3.6-35B-A3B groupwise-int measures **593 tok/s at C=1** —
   an A3B MoE activates ~3B params per token. That is the only path to a large multiple,
   and it is a model decision, not a tuning one.

## Not measured

Quality. Every number here is transport throughput. MTP is lossless by construction
(drafts are verified against the target model, so output should be identical to MTP-off),
but that was **not** verified on this host — no output-equivalence check was run between
`--spec off` and `--spec mtp`. Worth a fixed-seed diff before trusting it fully.

---

# Artifact A/B — groupwise-int vs nvfp4 (2026-08-24)

Both arms measured back-to-back in one session, `--draft-tokens 4`, `--kv-dtype bf16`,
`--lm-head-draft`, 10 samples each. **KV verified `resolved=65536 pages=1024/1024
runtime=5.19 GiB` on both arms**, so this is an artifact-only comparison — if VRAM had been
tight, `auto` would have silently resolved fewer pages and made it a config comparison.

| Arm | Artifact | Decode tok/s | sd | MTP acceptance | VRAM free |
|---|---|---:|---:|---:|---:|
| A | groupwise-int (16.96 GiB) | 166.5 | 6.3 | ~46% | 6,721 MiB |
| **B** | **nvfp4 (20.02 GiB)** | **182.7** | 9.1 | ~48% | 3,806 MiB |

**nvfp4 wins by +9.7%** (t≈4.6, unambiguous), against a +8.9% prediction from the published
Qwen3.6-27B ratio — the prediction held almost exactly. Best single sample: **197.2 tok/s**.

Acceptance is **unchanged** between arms (~46% vs ~48%). The gain is therefore pure FP4
compute on Blackwell's native tensor cores, not better speculation. That also settles the
earlier open question: the ~48% acceptance against the published ~68% is inherent to this
model, and no artifact or draft-window choice fixes it.

nvfp4 resident is 18.98 GiB (predicted 18.79 from the file-size ratio).

## draft-tokens behaves differently per artifact

| `--draft-tokens` | groupwise-int | nvfp4 |
|---:|---:|---:|
| 2 | 172.9 (n=5) | 161.0 |
| 3 | 169.7 (n=5) | 170.8 |
| 4 | **166.5** (n=10) | **182.7** |
| 5 | 158.2 (n=5) | 183.2 |

groupwise-int is flat across 2–4 then collapses at 5 (acceptance → 41%). nvfp4 climbs
monotonically and **plateaus** at 4–5 instead of collapsing. So the tuning does not transfer
between artifacts — re-sweep after any artifact change rather than carrying the value over.

## Context vs concurrency vs VRAM

KV tokens = `max-concurrency × max-context` (verified: 2 × 32,768 → 65,536). This matters
because **Hermes sends a ~24.8k-token system prompt**, so at 32k per slot only ~8k is left
for the actual conversation.

| Config (all nvfp4, dt=4) | Decode tok/s | Context/slot | Slots | Usable after Hermes' prompt | VRAM free |
|---|---:|---:|---:|---:|---:|
| **2 × 32k (current)** | **182.7** | 32,768 | 2 | ~8k | 3,556 MiB |
| 1 × 64k | 178.9 | 65,536 | 1 | ~40k | 3,812 MiB |
| 2 × 48k | 181.1 | 49,152 | 2 | ~24k | 1,596 MiB |

All three are within ~2% on throughput, so this is **not** a speed decision — it is a
context-vs-concurrency-vs-headroom decision:

- **1 × 64k is free.** KV actually *drops* to 4.81 GiB (CUDA graphs halve, 164 → 82 MiB).
  Five times the conversation room for 2% throughput. Cost: a second concurrent request
  queues instead of running.
- **2 × 48k** keeps both slots and triples usable context, but leaves 1,596 MiB free —
  close to the ~1 GiB condition that made LM Studio spill to CPU. The difference is that
  NInfer's KV is pre-allocated, so that space is genuinely spare rather than contested;
  still thin if anything else on the card wants memory.
- **2 × 32k** is the current default purely because it is the no-regression choice: same
  context as pre-tuning, so nothing about conversation length changes.

## Full progression

| Stage | Decode tok/s | vs baseline |
|---|---:|---:|
| LM Studio (operator-reported, degrading) | ~60 → 30 | — |
| NInfer groupwise-int, MTP off | 87.4 | 1.00× |
| NInfer groupwise-int, MTP dt=4 | 166.5 | 1.90× |
| **NInfer nvfp4, MTP dt=4** | **182.7** | **2.09×** |
| Best single sample observed | 197.2 | 2.26× |

## The 200 tok/s question — answered

**Not reachable as a sustained single-stream mean on this hardware.** 182.7 is where the
engine knobs land, individual samples touch 197, and NInfer's own best published figure for
any 27B on a 5090 is 202.4. We are within 10% of the measured ceiling of the design space.

Reaching 200+ requires changing a premise, not a setting:

1. **Aggregate rather than single-stream.** Already configured at C=2; published
   groupwise-int aggregate at C=2 is 247 tok/s (nvfp4 399.7). If the goal is total tokens
   across parallel agents, that target is already met.
2. **Change model class.** Qwen3.6-35B-A3B groupwise-int measures **593 tok/s at C=1** — an
   A3B MoE activates ~3B params per token. This is the only path to a large multiple, and
   it is a model decision with quality implications, not a tuning one.

## Still not measured

Output equivalence between `--spec off` and `--spec mtp`, and between the two artifacts.
MTP is lossless by construction (drafts are verified against the target model), but nvfp4 vs
groupwise-int is a genuine **quantization** difference and *will* produce different text.
No fixed-seed quality comparison was run. If output quality matters more than 9.7%, that
comparison should happen before nvfp4 is considered settled.

---

# Context scaling and the final config (2026-08-24)

Decisions taken: **nvfp4** artifact (quality risk accepted at +9.7%), **concurrency 1**
(workload is serialized, so slots buy nothing), context pushed as far as VRAM safely allows.

## Correction to the earlier int8 finding

The earlier note called `--kv-dtype int8` a "quality risk" not worth taking for zero
throughput. The throughput half stands. The framing was wrong:
`docs/performance.md:47,92,122` state **every published NInfer benchmark used INT8
group-64 KV**, and the live engine confirms it (`engine.kv_cache = "int8-group64"` in the
request log). So int8 is NInfer's *reference* configuration and bf16 is the off-default —
choosing int8 matches the config their 185.8/202.4 figures were measured in rather than
departing from it.

Relative to llama.cpp / LM Studio `q8_0` KV: same 8-bit width, but group-64 vs q8_0's
group-32, so ~8.25 vs ~8.5 effective bits per value — same class, slightly coarser
grouping, not an identical format.

## Context vs VRAM (nvfp4, concurrency 1, dt=4)

Decode throughput is **flat across every context length tested** (181–187 tok/s, all within
noise). Context is therefore purely a VRAM decision, not a speed one.

| Context | KV dtype | KV size | Free VRAM | tok/s |
|---:|---|---:|---:|---:|
| 64k | bf16 | 4.81 GiB | 3,812 MiB | 178.9 |
| 96k | bf16 | 6.93 GiB | 1,685 MiB | 184.4 |
| 128k | bf16 | 9.06 GiB | **269 MiB** | 184.2 |
| **128k** | **int8** | **4.94 GiB** | **4,037 MiB** | **181.3** |
| 192k | int8 | 7.13 GiB | 1,794 MiB | 187.4 |

**128k int8 strictly dominates 64k bf16**: double the context, more free VRAM, same speed.
128k bf16 loads and runs but leaves 269 MiB free — one browser tab from an OOM, since the
Windows compositor grows VRAM on its own. 192k int8 is reachable if 1.8 GB free is
acceptable.

## Long-context quality check (nvfp4 + int8 KV)

Needle-in-a-haystack, needles at three depths, single request:

| Prompt tokens | Depth 10% | Depth 50% | Depth 92% |
|---:|---|---|---|
| 33,657 | — | constant + technician OK | — |
| 86,537 | constant + technician OK | constant + technician OK | constant + technician OK |

6/6 exact retrievals at 86.5k with both quantizations active, at ~4,700 tok/s prefill.
Retrieval holds in the regime where int8 KV is theoretically weakest. This is a retrieval
check, **not** a generation-quality benchmark.

## Final configuration

    artifact          qwen3_8_27b_nvfp4.ninfer   (20.02 GiB, sha256 bb336052...)
    --spec mtp --draft-tokens 4 --lm-head-draft
    --kv-dtype int8            (group-64; NInfer's own benchmark default)
    --max-context 131072 --max-concurrency 1
    --request-log-jsonl /logs/requests.jsonl

    decode      ~181 tok/s        (2.07x the 87.4 MTP-off baseline)
    context     131,072 tokens    (~106k usable after Hermes' ~24.8k system prompt)
    VRAM        ~28.1 GiB used / ~4.0 GiB free
    KV          pre-allocated at startup, pages=2048/2048 -- does not grow under load

## Collapse watchdog

`tools/check-collapse.sh [n]` reads the request log and flags:

1. **Output-budget exhaustion rate** >15% — a looping model runs to its ceiling.
2. **Long generations that also hit the ceiling** (>=2000 tokens) — the clearest loop
   signature available.
3. **MTP acceptance** below 30% against the ~48% baseline — an incoherent model becomes
   unpredictable to its own drafter, so acceptance is a free coherence proxy.
4. **Decode drift** across the window — catches the LM Studio regression shape (a new VRAM
   tenant) rather than a quality problem.

**Hard limitation:** the request log is metadata only — `schema_version 10` carries no
response text (verified against a live record). Repetition cannot be detected directly, and
**junk output that terminates normally is invisible to this tool.** It checks for symptoms,
not quality.

Also worth knowing, from the live log: Hermes sends `tool_count: 45`,
`requested_output_tokens: 32768`, and a ~24.8k-token prompt with `enable_thinking: true`.
