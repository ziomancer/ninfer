# LM Studio → NInfer chat cutover — runbook

**Status: CUTOVER COMPLETE, 2026-08-23 ~22:55 MDT.** Steps 0–7 are done and verified;
only step 8 (a real reboot rehearsal) remains. Hermes is serving from NInfer with LM Studio
not running. Evidence: `../ninfer-spike/receipts/S1-gpu-passthrough.md` and `S2-S4-cutover.md`.

Scope: the **chat/agent** path only (Hermes' qwen3.8-27b). The embedding path left LM
Studio at the MCP-52 cutover and is untouched here.

LM Studio is **not being uninstalled**. It stays as the only independent reference for
the corpus vector space in the embedding parity gate (MCP Server/CLAUDE.md). What
changes: it is no longer started at boot and no longer serves chat.

## Hard constraint — one GPU

One 32,607 MiB RTX 5090. NInfer's artifact is 16.96 GiB resident; LM Studio's
qwen3.8-27b GGUF is 17.7 GiB. **Both do not fit.** Every step below assumes exactly one
engine holds weights at a time. This is why the boot script no longer starts LM Studio:
auto-starting it would race NInfer for VRAM and one would fail to load.

---

## DONE — 0. S1: engine proves out

`ninfer:local` (built 2026-08-21) runs under the nvidia runtime, sees the 5090, and
`ninfer-serve` is functional. Evidence: `../ninfer-spike/receipts/S1-gpu-passthrough.md`.

## DONE — 1. Compose + config

- `docker-compose.yml` — validated (`docker compose config` clean)
- `.env` — gitignored; loopback API key, models dir, port 3400, ctx 32768, GPU pinned by UUID
- `--model-id qwen/qwen3.8-27b` deliberately matches Hermes' existing `model.default`, so
  the cutover changes only `provider` and `base_url`, never the model name

## DONE — 2. Boot script

`MCP Server/scripts/Start-VHStack.ps1`:
- LM Studio launch, readiness wait, token plumbing and `Ensure-ModelLoaded` all removed
- The stale `$CalvinModel = "qwen/qwen3.6-27b"` pin is gone (it disagreed with Hermes'
  3.8, so every boot loaded a second 17 GB model nothing used)
- New NInfer tier with an artifact preflight, a VRAM warning, and a host-side
  HTTP `/health` probe
- New `-SkipChatModel` switch — frees the GPU for the parity gate
- Verified: full run completes in **7.6 s** and refuses NInfer cleanly when the artifact
  is absent, leaving the rest of the stack up

---

## DONE — 3. Download the artifact (16.96 GiB)

```
hf download neroued/Qwen3.8-27B-NInfer qwen3_8_27b.ninfer --local-dir %USERPROFILE%\.ninfer\models
```

Verify — a truncated download presents as a crash loop, not a checksum error:

```
# expect exactly 18210531328 bytes
ls -l ~/.ninfer/models/qwen3_8_27b.ninfer
# expect eec39564993d6e9c7d5e383382a760f093465c9d163ec9a1bd6b80199514bf3e
sha256sum ~/.ninfer/models/qwen3_8_27b.ninfer
```

The nvfp4 variant (`neroued/Qwen3.8-27B-nvfp4-NInfer`, 20.02 GiB) is the alternative:
Blackwell-native FP4, but 3 GiB more resident. Benchmark it later (spike S5); start here.

## DONE — 4. Free the GPU

Quit LM Studio **fully** (tray icon too, not just the window), then confirm the card is
actually released — a lingering process holding 17 GiB is the single most likely cause
of a failed first load:

```
nvidia-smi --query-gpu=memory.used --format=csv
```

Expect a few hundred MiB (text-embedder ~158 MiB + vision-embedder), not ~31 GiB.

## DONE — 5. Start NInfer and verify

```
cd <path-to-this-repo>
docker compose up -d
docker logs -f vigil-chat-model      # watch the artifact load
```

Then, from the host:

```
curl http://127.0.0.1:3400/health
curl http://127.0.0.1:3400/v1/models     # expect id "qwen/qwen3.8-27b"
```

`/v1/models` reporting `qwen/qwen3.8-27b` is what makes step 6 a two-line change.

## DONE — 6. Smoke test, including a tool call

Tool calling is what Hermes actually depends on — a passing plain completion proves
very little. Use the key from `.env` as the bearer token:

```
curl http://127.0.0.1:3400/v1/chat/completions \
  -H "Content-Type: application/json" -H "Authorization: Bearer $NINFER_API_KEY" \
  -d '{"model":"qwen/qwen3.8-27b",
       "messages":[{"role":"user","content":"What is the weather in Denver?"}],
       "tools":[{"type":"function","function":{"name":"get_weather",
         "parameters":{"type":"object","properties":{"city":{"type":"string"}},
                       "required":["city"]}}}]}'
```

Expect a `tool_calls` entry naming `get_weather`. If it answers in prose instead, stop —
Hermes will misbehave in ways that look like agent bugs rather than engine bugs.

## DONE — 7. Repoint Hermes

Rollback copy already taken: `~/AppData/Local/hermes/config.yaml.bak-pre-ninfer-20260823`.

Edit the first four lines of `~/AppData/Local/hermes/config.yaml`:

```yaml
model:
  default: qwen/qwen3.8-27b      # UNCHANGED — --model-id matches it
  provider: llamacpp             # was: lmstudio
  base_url: http://127.0.0.1:3400/v1   # was: ''
```

`llamacpp` is one of the local-server aliases Hermes resolves to its custom
OpenAI-compatible path (`hermes_cli/runtime_provider.py:76-86`), which is what NInfer
serves. Hermes also needs the API key — set it the way the profile expects (`hermes
model` / the profile's `api_key`), matching `NINFER_API_KEY` in `.env`.

Then a real multi-tool conversation, not a one-liner.

## TODO — 8. Full reboot rehearsal  ← the only step left

The point of the whole exercise is that the morning is fresh. Actually reboot, then:

```
type %USERPROFILE%\.vigil-harbor\startup.log
```

Expect `NInfer (chat) ..... OK — qwen3.8-27b` in the summary block.

---

## Post-cutover tuning — speculative decoding (2026-08-24)

Enabled MTP speculative decoding after the cutover. **Decode roughly doubled: 87.4 →
~170 tok/s (1.94×).** Full sweep, method, and VRAM accounting in `bench/RESULTS.md`;
harness is `bench/bench.sh` (repeatable, reads NInfer's own decode counter).

Then ran the artifact A/B: **nvfp4 beats groupwise-int by +9.7%** (182.7 vs 166.5 tok/s,
10 samples each, KV verified identical on both arms). Final: **182.7 tok/s, 2.09× the
MTP-off baseline.**

Final engine config lives in `.env` / `docker-compose.yml`:

    artifact  qwen3_8_27b_nvfp4.ninfer   (20.02 GiB, sha256 bb336052…)
    --spec mtp --draft-tokens 4 --lm-head-draft
    --kv-dtype int8                       (group-64; NInfer's own benchmark default)
    --max-context 131072 --max-concurrency 1
    --request-log-jsonl /logs/requests.jsonl

Operator decisions, 2026-08-24: nvfp4 accepted (+9.7%, quality risk acknowledged);
concurrency 1 because the workload is serialized; context pushed to 128k, which int8 KV
makes free. **~181 tok/s, 131,072-token context, ~4.0 GiB VRAM free.**

Monitoring: `tools/check-collapse.sh` — watches output-budget exhaustion, loop-shaped
generations, MTP acceptance, and decode drift. It cannot see response text, so junk that
terminates normally is invisible to it.

- `draft-tokens` 2/3/4 are indistinguishable (~170); 5 is strictly worse (158, acceptance
  collapses to 41%). MTP is the only backend for this model — DFlash is 35B-A3B only.
- `--kv-dtype int8` measured **zero** throughput gain but frees ~2 GiB. Left at bf16.
- MTP residency costs ~1.07 GiB. Final: 28,632 MiB used / 3,556 MiB free.
- `draft-tokens` tuning does **not** transfer between artifacts: groupwise-int is flat
  2–4 then collapses at 5; nvfp4 climbs to 4 and plateaus. Re-sweep after any artifact change.
- **Open decision:** context vs concurrency. KV tokens = `concurrency × max-context`, and
  Hermes' system prompt is ~24.8k tokens, so 32k/slot leaves only ~8k for conversation.
  **Resolved:** `1 × 128k` with int8 KV — 131,072 tokens (~106k usable after Hermes'
  prompt), ~4.0 GiB free, ~181 tok/s. int8 halves KV at zero throughput cost, so this
  strictly dominates the `1 × 64k` bf16 option it replaced. See `bench/RESULTS.md`.
- **Not verified:** output equivalence between `--spec off` and `--spec mtp`. MTP is
  lossless by construction (drafts are verified against the target model) but no
  fixed-seed diff was run on this host.

For context on the LM Studio baseline this replaced: the operator reported ~60 tok/s
degrading to 30–40 with CPU spill. That is the expected behaviour at ~1 GiB of headroom —
a growing KV cache has nowhere to go. NInfer claims its KV up front, so the failure mode
is absent by construction rather than fixed.

---

## Operator control -- no agent required

`VH-Model.ps1` in this directory. Verbs:

    .\VH-Model.ps1              status (default) -- state, config, VRAM, recent decode rate
    .\VH-Model.ps1 stop         evict the model, free ~24 GiB VRAM
    .\VH-Model.ps1 start        load and wait until it actually serves
    .\VH-Model.ps1 restart      reload, picking up .env changes
    .\VH-Model.ps1 parity       evict + print the embedding parity-gate steps
    .\VH-Model.ps1 context <n>  set max-context and reload
    .\VH-Model.ps1 artifact nvfp4|groupwise
    .\VH-Model.ps1 logs         tail the engine log
    .\VH-Model.ps1 health       collapse watchdog

Also in the Start Menu under **Vigil Harbor** (searchable from Start, draggable to the
taskbar): Model Status / Start / Stop (free GPU) / Restart / Health Check / Free GPU for
Parity Gate. They open with `-NoExit` so output stays readable.

Verified round-trip: `stop` frees to 29,805 MiB free; `start` serves again in ~60 s;
Hermes reconnects with no config change.

Two things the script deliberately does:

- **It never touches Hermes' config.** Stopping the engine does not repoint Hermes -- Hermes
  simply cannot reach a model until you start it again. That keeps the two concerns
  separate, so an eviction is never a config migration.
- **`context` re-reads the KV line after reload and tells you to check `pages=N/N`.** If VRAM
  is short, `--kv-capacity auto` silently resolves *fewer* pages instead of refusing to
  start, so you would quietly get less context than you asked for.

---

## Rollback (any step)

1. `cd ninfer && docker compose down`
2. Start LM Studio, load `qwen/qwen3.8-27b`
3. `copy config.yaml.bak-pre-ninfer-20260823 config.yaml` in `~/AppData/Local/hermes`
4. Boot script: `git -C "..\MCP Server" checkout scripts/Start-VHStack.ps1`

Nothing in this cutover writes to the corpus, so there is no data-loss path — the
rollback is purely "which process serves chat".

## Known gaps

- **Container healthcheck is TCP-only.** The image ships no curl/wget/python3, so
  `docker inspect` health proves the port is accepting connections, not that the model
  loaded. The boot script's host-side HTTP `/health` probe is the real check. A wedged-
  but-listening server would read as healthy to Docker.
- **No automatic fallback.** If NInfer is down, Hermes has no chat model —
  `fallback_providers` is `[]`. Consider populating it once NInfer has a track record.
- **NInfer only supports its registered Qwen artifacts.** Switching models is not a
  drop-in the way LM Studio's library was.
- **Not yet benchmarked** against the LM Studio baseline (spike S5). Adopt/reject is
  still formally open (S6).
