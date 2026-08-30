# NInfer → Hermes portable deployment — new-host runbook

Stands up the NInfer chat engine serving `qwen/qwen3.8-27b` on a machine currently
using LM Studio, and repoints that machine's Hermes at it. This is the portable
version of the cutover recorded in `../CUTOVER.md` (origin host: single RTX 5090,
completed 2026-08-23).

Scope: the **chat/agent** path only. If the target machine also runs an embedding
lane through LM Studio, that is a separate cutover — do not touch it here.

What travels to the target:

| Piece | How it travels |
|---|---|
| `ninfer:local` Docker image (4.67 GB) | `docker save` tar in the bundle (`Make-Bundle.ps1`) — preferred; bit-identical to the validated engine |
| Model artifact (17–20 GiB) | **Not** in the bundle by default — download from HuggingFace on the target and hash-verify (step 2) |
| Repo files (compose, VH-Model.ps1, bench, watchdog, this runbook) | In the bundle |
| `.env` | Never travels — created per-host from `.env.example` (step 3) |
| Hermes config change | Two lines, edited by hand with a backup (step 6) |

---

## 0. Preflight — gates, in order

**GPU.** The target is the same build as the origin — a single RTX 5090 (32,607
MiB), exactly what NInfer targets — so the origin's final config (nvfp4, MTP
dt=4, int8 KV, 128k context) carries over unchanged. Confirm, and grab the UUID
for `.env` while you're here:

```
nvidia-smi --query-gpu=name,memory.total,uuid --format=csv,noheader
```

Expect `NVIDIA GeForce RTX 5090, 32607 MiB, GPU-…`. Anything else, stop and
reassess — every number in this runbook assumes that card.

**Docker.** Docker Desktop on the WSL2 backend with the nvidia container runtime:

```
wsl --status
docker info --format "{{json .Runtimes}}"     # must include "nvidia"
```

**Port.** 3400 free on loopback: `netstat -ano | findstr :3400` should be empty.

**VRAM is exclusive.** One engine holds weights at a time. LM Studio keeps serving
until step 5 — nothing here needs the GPU before then.

## 1. Engine image

On the origin machine, `deploy\Make-Bundle.ps1` produces a bundle folder containing
`ninfer-image.tar` plus these repo files and a hash manifest. Transfer the folder
(robocopy over the tailnet, external disk — do **not** `Compress-Archive` it;
PS 5.1 zip mishandles >4 GiB entries). On the target:

```
docker load -i ninfer-image.tar
docker image ls ninfer:local        # expect a4764664cf8b, built 2026-08-21
```

Fallback only: rebuild from source (`github.com/Neroued/ninfer`, Dockerfile in
repo root). Upstream has **no tagged releases**, so a rebuild today is not the
engine that was validated — if you rebuild, re-run the full smoke of step 5.

Sanity: `docker run --rm --runtime nvidia --gpus all --entrypoint nvidia-smi ninfer:local`
must show the target's GPU.

## 2. Model artifact

Download on the target (needs the `hf` CLI, no auth required). nvfp4 is what
serves; groupwise-int is optional — only worth the 17 GiB if you want the
`VH-Model.ps1 artifact groupwise` fallback available offline:

```
# nvfp4 — the serving artifact (20 GiB)
hf download neroued/Qwen3.8-27B-nvfp4-NInfer qwen3_8_27b_nvfp4.ninfer --local-dir %USERPROFILE%\.ninfer\models
# groupwise-int — optional fallback (17 GiB)
hf download neroued/Qwen3.8-27B-NInfer qwen3_8_27b.ninfer --local-dir %USERPROFILE%\.ninfer\models
```

Verify — a truncated download presents as a crash loop, not a checksum error:

| Artifact | Bytes (exact) | SHA-256 |
|---|---|---|
| `qwen3_8_27b_nvfp4.ninfer` | 21,492,695,040 | `bb3360522a06e136e0367f5703414d26272b7285c8a6ab6194135c17dbd81b32` |
| `qwen3_8_27b.ninfer` | 18,210,531,328 | `eec39564993d6e9c7d5e383382a760f093465c9d163ec9a1bd6b80199514bf3e` |

```
Get-FileHash $env:USERPROFILE\.ninfer\models\<file> -Algorithm SHA256
```

## 3. Per-host config

```
copy .env.example .env
```

Only two values need filling: `NINFER_API_KEY` (generate fresh) and
`NINFER_GPU_DEVICE_ID` (the UUID from step 0). Everything else already mirrors
the origin 5090's measured final config.

Validate: `docker compose config` must render clean.

## 4. Free the GPU

Quit LM Studio **fully** (tray icon too). A lingering process holding 17 GiB is
the single most likely cause of a failed first load:

```
nvidia-smi --query-gpu=memory.used --format=csv    # expect a few hundred MiB
```

Also **disable LM Studio's auto-start now** (LM Studio settings, and check
`shell:startup` / Task Manager → Startup apps). If it relaunches at boot it will
race NInfer for VRAM and one of them fails to load.

## 5. Start and verify

```
.\VH-Model.ps1 start        # compose up + waits for /health
```

Then three checks, all required:

1. `curl http://127.0.0.1:3400/v1/models` → id `qwen/qwen3.8-27b`.
2. `docker logs vigil-chat-model | findstr "KV capacity"` → `pages=N/N` equal.
   If N<M, VRAM was short and `--kv-capacity auto` silently downsized the cache.
3. **Tool-call smoke** — the thing Hermes actually depends on; a plain completion
   proves very little (bash, key from `.env`):

```
curl http://127.0.0.1:3400/v1/chat/completions \
  -H "Content-Type: application/json" -H "Authorization: Bearer $NINFER_API_KEY" \
  -d '{"model":"qwen/qwen3.8-27b",
       "messages":[{"role":"user","content":"What is the weather in Denver?"}],
       "tools":[{"type":"function","function":{"name":"get_weather",
         "parameters":{"type":"object","properties":{"city":{"type":"string"}},
                       "required":["city"]}}}]}'
```

Expect a `tool_calls` entry naming `get_weather`. Prose instead → **stop**; Hermes
will misbehave in ways that look like agent bugs.

While you're here, sanity-check throughput: `.\VH-Model.ps1 status` should show
decode in the ~180 tok/s neighborhood the origin 5090 measured. Dramatically
lower on identical hardware means another VRAM tenant (see step 7).

## 6. Repoint Hermes

Back up first:

```
copy %USERPROFILE%\AppData\Local\hermes\config.yaml %USERPROFILE%\AppData\Local\hermes\config.yaml.bak-pre-ninfer
```

Edit the model block (profile config if the target uses a non-default profile —
note `--profile` overrides `HERMES_HOME`):

```yaml
model:
  default: qwen/qwen3.8-27b            # UNCHANGED — NInfer's --model-id matches it
  provider: llamacpp                   # was: lmstudio
  base_url: http://127.0.0.1:3400/v1   # was: ''
```

`llamacpp` is a local-server alias Hermes resolves to its custom OpenAI-compatible
path. Set the API key the way the profile expects (`hermes model` / the profile's
`api_key`) to match `NINFER_API_KEY` in `.env`. Then run a real multi-tool
conversation, not a one-liner.

Because both engines answer to the same model name, **the model string never
identifies the lane — only `base_url` does.** Check what a request is actually
hitting, not what model it claims.

## 7. Close the :1234 trap

On the origin host, retired-but-installed LM Studio **kept listening on :1234 and
kept JIT-loading models** — a stale client dialing it loaded a second 17 GiB model
onto a full GPU, spilled to system RAM, and collapsed NInfer decode 190 → 56 tok/s
while looking like "Hermes is on CPU". After the cutover, audit the target for
anything still pointing at :1234 (hindsight/daemon profile envs, secondary Hermes
profiles, scripts) and repoint them to 3400 (chat) / their real embedding endpoint.

## 8. Tune (optional, after everything is green)

- On identical hardware `NINFER_DRAFT_TOKENS=4` should hold; `bench\bench.sh`
  (from Git Bash; reads `../.env`) verifies in ~5 minutes. The sweep only becomes
  mandatory again if the **artifact** changes — optima do not transfer between
  artifacts (nvfp4 → 4; groupwise → 2..4 flat, 5 strictly worse).
- Grow context with `.\VH-Model.ps1 context <n>`; it reprints the KV line —
  insist on `pages=N/N`.
- Watchdog: `.\VH-Model.ps1 health` (`tools/check-collapse.sh`). It reads
  `logs/requests.jsonl`, which is append-only and never rotated — prune manually.

## Boot integration

Simplest portable path: the container is `restart: unless-stopped`, so Docker
Desktop set to start at login brings the model back by itself — no boot script
needed. The origin host's `Start-VHStack.ps1` tier (artifact preflight, VRAM
warning, host-side HTTP probe) lives in the MCP Server repo and only makes sense
if the target runs the full Vigil Harbor stack.

After setting it up, actually reboot and verify serving — that rehearsal is the
one step the origin cutover still has open.

## If you're also running `hermes update` on the target

Hard-won on the origin host (2026-08-24, v0.18.2 → v0.20.5):

- **`hermes update`'s restart messages lie on Windows** — it reports gateways
  restarted that are down. `hermes gateway status` afterwards and restart
  explicitly.
- **Dashboard build needs Node 26** (`.nvmrc`); `--skip-build` is the fallback.
  `hermes dashboard --stop` only tracks instances it launched — a stray one on
  :9119 must be killed by PID.
- **Stop the gateways before any dependency install** — they hold file locks in
  the venv (`WinError 5` on `cryptography\...\_rust.pyd`).
- The venv is **uv-managed, no pip**: `uv pip install ... --python <venv python>`.
- Never bare-`git fetch` in `hermes-agent` (~1400 branches) — always
  `git fetch origin main`.

## Rollback (any step)

1. `docker compose down` (or `.\VH-Model.ps1 stop`)
2. Start LM Studio, load `qwen/qwen3.8-27b`, re-enable its auto-start if you
   disabled it
3. Restore `config.yaml.bak-pre-ninfer` in `%USERPROFILE%\AppData\Local\hermes`

Nothing in this deployment writes to any corpus — rollback is purely "which
process serves chat".

## Known gaps (inherited from the origin cutover)

- Container healthcheck is TCP-only (image ships no curl/wget/python3); a
  wedged-but-listening server reads healthy to Docker. `VH-Model.ps1 status`
  does the real HTTP probe.
- No automatic fallback: if NInfer is down, Hermes has no chat model
  (`fallback_providers` is `[]`).
- NInfer serves only its registered Qwen artifacts — model switching is not a
  drop-in the way LM Studio's library was.
