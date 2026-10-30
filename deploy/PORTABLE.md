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
| `ninfer:local` Docker image (4.69 GB) | `docker save` tar in the bundle (`Make-Bundle.ps1`) — preferred; bit-identical to the validated engine |
| Model artifact (17–20 GiB) | In the bundle with `-IncludeArtifacts nvfp4` — preferred; these are the validated bytes (step 2) |
| Repo files (compose, VH-Model.ps1, bench, watchdog, this runbook) | In the bundle |
| `.env` | Never travels — created per-host from `.env.example` (step 3) |
| Hermes config change | Two lines, edited by hand with a backup (step 6) |

---

## 0. Preflight — gates, in order

**GPU.** The target is the same build as the origin — a single RTX 5090 (32,607
MiB), exactly what NInfer targets — so the origin's final config (nvfp4, MTP
dt=4, int8 KV, 128k context, 6 GiB context capacity) carries over unchanged. Confirm, and grab the UUID
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
docker image ls ninfer:local        # expect acd5a0174f82, built 2026-10-30 from upstream 1882c6ad
```

Fallback only: rebuild from the `vigil-deploy` branch of `github.com/ziomancer/ninfer`:
`git -c core.autocrlf=false archive HEAD | docker build --pull -t ninfer:local -`. Archiving
keeps LF line endings out of Windows' reach. If you rebuild, re-run the full smoke of step 5.
Sanity-check GPU access with `--gpus all`; without it the binaries cannot load `libcuda.so.1`.

Sanity: `docker run --rm --runtime nvidia --gpus all --entrypoint nvidia-smi ninfer:local`
must show the target's GPU.

## 2. Model artifact

The engine reads only v3 artifacts. Copy the validated v3 file from the bundle into
`%USERPROFILE%\.ninfer\models`. nvfp4 is what serves; groupwise-int is optional, only worth the
17 GiB if you want the `VH-Model.ps1 artifact groupwise` fallback.

Do not substitute a HuggingFace download without re-validating. Those files are also v3 but are
different artifacts (nvfp4 is 23.7 GB against 21.5 GB here) and have not been benchmarked on this
stack.

If the target already holds the older v2 files, upgrade them instead of transferring. Run under
WSL, because the tool uses POSIX-only file calls, with the output in a new directory:
`python3 tools/upgrade_ninfer_v2_to_v3.py <v2 file> <v3 file>`.

Verify — a truncated copy presents as a crash loop, not a checksum error:

| Artifact | Bytes (exact) | SHA-256 |
|---|---|---|
| `qwen3_8_27b_nvfp4.ninfer` | 21,492,938,224 | `31c99b74582f1292f80c0bfd1e5f63f4b4a1a1d8731d8c71be78dca1f46eeed6` |
| `qwen3_8_27b.ninfer` | 18,210,749,936 | `da624891f1ac24733d9169781fb78fc10fe30b85edfe91b60b122101cef87946` |

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
2. `docker logs vigil-chat-model | findstr "context"` → `device 6.00 GiB` and `KV ~N tokens`
   with N at least 131072 (about 163k is expected). `nvidia-smi` should show 3.0–4.0 GiB free, depending on what else holds the card.
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
decode in the ~155–160 tok/s neighborhood the origin 5090 measured with `bench\bench.sh`. Dramatically
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
- Grow context with `.\VH-Model.ps1 context <n>`; it reprints the context line. Raise
  `NINFER_CONTEXT_CAPACITY` too if the `KV ~N tokens` estimate falls below the new limit.
- Watchdog: `.\VH-Model.ps1 health` (`tools/check-collapse.sh`). It reads
  `logs/requests.jsonl`, which is append-only and never rotated — prune manually.
- Loading/evicting without a shell: **double-click `VH-Model-Toggle.cmd`** (ships in
  the bundle). It runs `VH-Model.ps1 toggle` — evict if the model is up, load if it
  is down — in a console that stays open so you can read the closing VRAM line. For
  a Desktop button, right-click it → Send to → Desktop (create shortcut).

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
