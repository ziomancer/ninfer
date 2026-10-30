# Engine migration plan: `ninfer:ca-20261021` → upstream `1882c6ad`

Temporary plan. Delete it when stage 6 is done; `CUTOVER.md` and `deploy/PORTABLE.md` keep the
durable result. Reviewed by Codex (gpt-5.6-sol) on 2026-10-30; its findings are incorporated below.

## Status (2026-10-30)

Stages 0–5 and the origin-host cutover are done; the new engine is serving. Remaining in stage 6:

- Real reboot rehearsal (needs the operator's machine free).
- 7-day soak, ending 2026-11-06. Then delete the v2 artifacts in `models\`, the old images, the
  `..\ninfer-rollback` worktree, and this plan.
- Texas: `Make-Bundle.ps1 -IncludeArtifacts nvfp4`, then `PORTABLE.md`.

Deviations from the text below:

- Free VRAM is 3.0–4.0 GiB rather than ≥ 3.9 GiB. Accepted at 6 GiB: the embedder gate passed, and
  meeting 3.9 would cut the KV estimate to about 137k.
- `Start-VHStack.ps1` restarts the stopped vision embedder on every run (about 0.5 GiB).
- Texas takes the upgraded artifact, because HuggingFace's v3 files are different and unvalidated.
- Git for Windows' autocrlf: build with `git -c core.autocrlf=false archive`, not from a checkout.

## Goal and done criteria

Move the Hermes chat engine on both RTX 5090 hosts to upstream master `1882c6ad`, with the same
model (`qwen3.8-27b/nvfp4`), the same public alias (`qwen/qwen3.8-27b`), and the operator tooling
working. Done means:

- Hermes completes a real multi-tool conversation through the new engine.
- Decode is within 5% of the old engine, both measured in stage 0/5 with one harness and one formula.
- A request with a measured ~100k-token prompt succeeds (the real workload has reached 98,351).
- Free VRAM after startup is at least the old engine's 3.9 GiB, and the embedders stay on the GPU.
- `VH-Model.ps1` verbs, `bench/bench.sh`, and `tools/check-collapse.sh` all report correct data.
- Rollback to the old engine has been exercised, not just written down.

Not in scope: Flash Next, GLM, DFlash2, Vision, Spark, the `upstream/dev` dashboard, and TOML config.
Take `master` by SHA; upstream has no tags and `dev` is a day newer but unmerged.

## Current state (checked 2026-10-30)

- Overlay: `vigil-deploy` = `d9dbe1ce` + 2 commits (1 unpushed), plus uncommitted toggle work in
  `VH-Model.ps1`, `deploy/Make-Bundle.ps1`, `deploy/PORTABLE.md`, and new `VH-Model-Toggle.cmd`.
- Image: `ninfer:local` = `ninfer:ca-20261021` (`0655fad2f061`), the Aug 21 build plus an in-place
  `ca-certificates` upgrade. **The running binary is not `d9dbe1ce`:** it was built nine days earlier
  and writes request-log schema 10, where `d9dbe1ce` declares 18. Its source commit is unrecorded.
  The baseline is therefore observed behavior, below, not the `d9dbe1ce` source.
- Container `vigil-chat-model` is absent right now, so the engine is currently off.
- Artifacts: both `.ninfer` files in `%USERPROFILE%\.ninfer\models` have v2 magic. nvfp4 has 1124
  objects including `text/draft_head`, a count the upgrader accepts.
- Baseline from the last `server_start` record in `logs/requests.jsonl`:
  nvfp4, MTP draft 4, optimized head, int8-group64 KV, max context 131072, concurrency 1, prefix reuse
  on, thinking on, preserve thinking **off**, default output 32768, pending timeout 30 s, runtime
  reservation 4.94 GiB, available after startup 3.91 GiB.
- Workload in that log: 10,033 completed requests; 290 failed with queue expiry and 57 with client
  disconnect. Largest recent prompt 98,351 tokens. Real-traffic decode median 161.7 tok/s.
- 693 GB free on C:. WSL Ubuntu has Python 3.12.3, no `uv`.

## What changes in the engine

Read from `upstream/master` source or docs, and confirmed by the review unless noted.

| Change | Effect on us | Handling |
|---|---|---|
| Reader rejects v2 artifacts | Crash loop on load | Stage 2 upgrade |
| Unknown CLI flags are errors (`options.cpp:100`) | Compose fails to start | Flag mapping |
| `--context-capacity auto` searches up to the usable device budget (`context_capacity.cpp`); 512 MiB headroom is a planning allowance, not a guaranteed free margin. Old auto was capped by `concurrency × max-context` | The 3.9 GiB margin likely disappears, and later VRAM users compete | Explicit capacity, stage 4 |
| `preserve_thinking` default was off, now `model`, and the Qwen3.8 template retains reasoning when undefined | Multi-turn prompts grow, changing cache keys, capacity use, and output | Pass `--no-preserve-thinking` |
| Host context backing default on RTX 5090: 8 GiB + eight StateImages, fixed at startup | More RAM inside the WSL2 VM | Measure in stage 4; knob if it hurts |
| `max_context` is logical; input plus requested output count against it; pool shared by KV and State, with pressure reclaim and pause/replay | `pages=N/M` no longer exists | Startup `KV ~N` estimate, `max_model_len`, plus the long-prompt test |
| Upgrader installs the maintained chat template | Prompt rendering and tool calls can change for Hermes | Stage 5 gates |
| Operational log format is now `req#N done \| ... \| decode X tok/s`, and that rate uses wall-clock generation time | `bench.sh` and `VH-Model.ps1 status` find nothing, silently; the rate is not comparable to the old one | Stage 3: read `requests.jsonl` |
| Request log schema 10 → 31 | Watchdog fields retained, `output_limit` retained | Confirm on a live record; new log at cutover |
| `/health` now returns 503 on engine-wide failure | Better signal; `VH-Model.ps1` treats non-200 as not serving | None |

Flag mapping for `docker-compose.yml`:

| Old | New |
|---|---|
| `--kv-capacity auto` | `--context-capacity ${NINFER_CONTEXT_CAPACITY:-auto}` |
| `--log-stats-interval-ms 0` | `--stats-interval 0ms` |
| `--lm-head-draft` | `--proposal-head optimized` |
| `--default-max-tokens N` | `--max-tokens N` |
| (none, default off) | `--no-preserve-thinking` |
| (none, default off) | `--no-vision` (operator doesn't use Vision; explicit so a config change can't load it) |
| (none, default 30 s) | `--pending-timeout ${NINFER_PENDING_TIMEOUT:-600s}` |

The pending timeout is a deliberate behavior change, not part of the port. 290 requests expired at 30 s
under the old engine, because one 32768-token generation runs about 3 minutes at concurrency 1. Stage 5
confirms Hermes itself waits long enough to benefit.

Unchanged per `schema.cpp`: positional path, `--host`, `--port`, `--model-id`, `--max-context`,
`--max-concurrency`, `--api-key`, `--spec`, `--draft-tokens`, `--kv-dtype`, `--request-log-jsonl`.

## Key decisions

1. **Merge, not rebase.** The overlay touches only ops files; the only conflict is `.gitignore`
   (keep both sides). Merge in a worktree so the primary checkout stays runnable.
2. **New artifact directory, same filenames.** Write v3 files to `%USERPROFILE%\.ninfer\models-v3\`.
   Only `NINFER_MODELS_DIR` changes. `Start-VHStack.ps1` and the `artifact` verb key on filename, so
   they work unmodified, and v2 stays in place as the rollback.
3. **One Compose project everywhere.** `docker-compose.yml` hardcodes `container_name`, and the project
   name comes from the directory, so two checkouts collide and `down` from the wrong one leaves the
   container behind. Stage 0 adds `name: ninfer` and `image: ${NINFER_IMAGE:-ninfer:local}`, *before*
   the rollback tag, so old and new overlays share one project and each `.env` selects its image.
4. **Like-for-like first, tuning second.** Migrate with int8 and draft tokens 4 so regressions are
   attributable. Then one bounded A/B: KV int8 vs fp8, draft tokens 3 vs 4. Adopt only a measured gain.
5. **Explicit context capacity in `.env`.** Size it in stage 4, ship the value in `.env.example`.
6. **One decode formula on both engines.** `(completion_tokens - 1) / timings_seconds.decode` from
   `requests.jsonl`, the old operational metric's definition. Both engines are measured by the same
   script, so the historic 181 is context and not the gate. The new wall-clock log rate is recorded
   separately and never compared with it.

## Stages

Each stage has a gate. Stop at a failed gate.

### 0. Freeze the rollback point and measure the baseline

- Commit the toggle work; add `name: ninfer` and `${NINFER_IMAGE:-ninfer:local}` to compose; rewrite
  `bench/bench.sh` to resolve `.env` and `logs/` from its own directory and compute decode from
  `requests.jsonl` per decision 6. Add `NINFER_DEFAULT_MAX_TOKENS=32768` to `.env.example`, which
  lacks it, so Texas would otherwise fall to 8192.
- Add `.env.*` and `!.env.example` to `.gitignore`, since only `.env` is ignored today. Set
  `NINFER_IMAGE=ninfer:ca-20261021` in `.env` and copy it to `.env.pre-v3`, which holds the key.
- Start the old engine. Save its `server_start` record to a local baseline file. Run `bench.sh` with 10
  samples, then stop it.
- Tag `pre-v3-engine`; push the branch and tag to `origin`.
- Gate: baseline tok/s and `server_start` saved; `git status` clean apart from this plan.

### 1. Merge and build (no GPU)

- Worktree `..\ninfer-v3` on new branch `vigil-deploy-v3`; `git merge 1882c6ad`, resolving `.gitignore`.
- `docker build --pull -t ninfer:1882c6ad .`. The rebuild takes current `ca-certificates`, so the
  Oct 21 patch layer has no successor. The review found the Dockerfile coherent with CUDA 13.1.2; the
  remaining risk is parallel CUDA compilation exhausting WSL2 memory.
- Gate: image builds; `docker run --rm --gpus all --entrypoint ninfer-serve ninfer:1882c6ad --help`
  lists every mapped flag. `--gpus` is required; without it the binary cannot load `libcuda.so.1`.

### 2. Upgrade artifacts (no GPU)

- **Run under WSL Ubuntu, not Windows.** The upgrader calls `os.posix_fadvise` and `os.fdatasync`
  unconditionally, so Windows Python fails. Those calls and `os.link` were tested on `/mnt/c` on
  2026-10-30. Docs name Python 3.11; the script is stdlib-only with no version check, so use 3.12.3 unless
  `uv` is added.
- `python3 tools/upgrade_ninfer_v2_to_v3.py <v2> <models-v3 path>` from the worktree, nvfp4 first, then
  groupwise-int. Record output SHA-256; upstream's published hashes apply only to downloads.
- Gate: outputs have v3 magic; v2 hashes still match `PORTABLE.md`.

### 3. Overlay changes (worktree)

- `docker-compose.yml`: flag mapping and stale comments.
- `.env.example`: new knobs; replace `pages=N/M` guidance. Drop the unused `NINFER_THINKING_BUDGET`
  from `.env` (compose does not read it).
- `VH-Model.ps1`: `status` decode from JSONL; `context` verb prints the `KV ~N` startup line and
  `max_model_len`; status shows capacity; crash-loop hint mentions v2 artifacts.
- `tools/check-collapse.sh`: schema comment; re-baseline acceptance in stage 5.
- `Make-Bundle.ps1` / `PORTABLE.md` / `CUTOVER.md`: image ID, artifact hashes, check steps,
  post-migration section.
- Worktree `.env`: copy from `.env.pre-v3` (git does not populate it), then set `NINFER_IMAGE=ninfer:1882c6ad`
  and `NINFER_MODELS_DIR` to `models-v3`. Delete it after stage 5.
- Gate: `docker compose config` renders the expected image, mount, and flags; `bash -n`; scripts parse.

### 4. First load and capacity sizing (GPU, Hermes down)

- From the worktree. The `name: ninfer` project replaces any primary-checkout container.
- Load with `auto`; record pool size, `KV ~N`, `max_model_len`, free VRAM, WSL host RAM.
- Set `NINFER_CONTEXT_CAPACITY`, starting from the old 4.94 GiB reservation, to the largest value
  leaving ≥ 3.9 GiB free with `KV ~N` ≥ 131072. Vision is already off, so turning it off frees nothing.
  If both cannot hold, stop and decide with the operator between margin, context, and fp8. Update the `$NInferKvGiB` diagnostic in
  `MCP Server/scripts/Start-VHStack.ps1` to this total (separate repo, separate commit).
- Gate: margin and estimate met; restarting the text embedder with NInfer loaded keeps it on the GPU.
  Embedder CPU fallback puts new writes in the wrong vector space, so this gate is hard.

### 5. Behavior and performance (GPU, Hermes down or pointed here)

- Diff the new `server_start` against the stage 0 baseline, field by field. Explain every difference;
  this is the catch-all for defaults nobody listed.
- `/health`, `/v1/models` id; non-streaming and **streaming** tool-call smoke.
- Long prompt: measure the length, send about 100k tokens with `max_tokens: 64`, since the 32768 default
  would exceed 131072 and fail for the wrong reason. Confirm the logged prompt count; repeat the exact
  prompt and confirm reused prefix tokens.
- A second request during a long generation waits rather than failing. Confirm Hermes' client timeout.
- `bench.sh` 10 samples: mean ≥ 95% of stage 0. Record acceptance as the new watchdog baseline.
- `check-collapse.sh` reads a live schema-31 record; every `VH-Model.ps1` verb works.
- Hermes: real multi-tool conversation including thinking turns; tool calls and reasoning parse correctly.
- A/B per decision 4, if the gate above passes.

### 6. Cutover, soak, Texas

- `docker compose down` from the worktree. Copy the worktree `.env` to `.env.v3`, with
  `NINFER_IMAGE` removed once `ninfer:local` is retagged.
- Merge `vigil-deploy-v3` into `vigil-deploy` in the primary checkout; archive `logs/requests.jsonl` as
  `requests.schema10.jsonl`; install `.env.v3` as `.env`; `docker tag ninfer:1882c6ad ninfer:local`.
- `Start-VHStack.ps1` full run, then the real reboot rehearsal `CUTOVER.md` step 8 still lists.
- Run the rollback drill below, then repeat the forward steps it names.
- Soak 7 days using `VH-Model.ps1 health`. Then delete v2 artifacts, old images, the rollback worktree,
  and this plan.
- Texas: `Make-Bundle.ps1` after the soak. Artifacts come from HF only if a header check shows v3 (README
  implies it, unverified), otherwise from the bundle. Hash table lists the source used.
- Push `vigil-deploy`; optionally fast-forward `origin/master` to `1882c6ad`. Public fork: no host paths
  or UUIDs.

## Rollback

Hermes config never changes, so rollback is engine-only. v2 artifacts stay untouched through the soak.

**Drill or temporary rollback** (leaves the primary checkout on v3):

1. `docker compose down` in the primary checkout.
2. `git worktree add ..\ninfer-rollback pre-v3-engine`; copy `.env.pre-v3` there as `.env`, which selects
   `ninfer:ca-20261021` and the v2 directory.
3. `docker compose up -d` there; check `/v1/models` and the tool-call smoke.

**Forward again:** `docker compose down` in `..\ninfer-rollback`, `.\VH-Model.ps1 start` in the primary
checkout, then `/health`, `/v1/models`, and the tool-call smoke.

**Permanent:** `git revert -m 1 <merge>` on `vigil-deploy`, install `.env.pre-v3` as `.env`,
`docker tag ninfer:ca-20261021 ninfer:local`, `.\VH-Model.ps1 start`.

## Operator-visible impact

Hermes loses chat for stage 0's baseline, stages 4–5, and cutover restarts. The engine is off today, and
the GPU cannot host old and new at once.
