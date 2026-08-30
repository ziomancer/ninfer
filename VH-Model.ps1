#Requires -Version 5.1
<#
  VH-Model.ps1 -- operator control for the local NInfer chat engine.

  Lets you load/evict the model and inspect it without an agent driving. The engine is a
  docker compose project in this directory; every setting is a knob in .env.

  Usage:
    .\VH-Model.ps1                 # status (default)
    .\VH-Model.ps1 stop            # evict the model, free ~24 GiB VRAM
    .\VH-Model.ps1 start           # load the model, wait until it serves
    .\VH-Model.ps1 restart
    .\VH-Model.ps1 parity          # evict, then print the embedding parity-gate steps
    .\VH-Model.ps1 context 65536   # set max-context and reload
    .\VH-Model.ps1 artifact nvfp4  # switch artifact (nvfp4 | groupwise) and reload
    .\VH-Model.ps1 logs            # tail the engine log
    .\VH-Model.ps1 health          # collapse watchdog

  Nothing here touches Hermes' config. Switching the engine off does NOT repoint Hermes --
  it will simply fail to reach a model until you switch it back on.
#>
param(
    [Parameter(Position=0)][string]$Action = "status",
    [Parameter(Position=1)][string]$Value
)

$Dir       = $PSScriptRoot
$Container = "vigil-chat-model"
$EnvFile   = Join-Path $Dir ".env"

function Get-EnvVal([string]$Key, [string]$Default) {
    if (-not (Test-Path $EnvFile)) { return $Default }
    $m = Select-String -Path $EnvFile -Pattern "^\s*$Key\s*=\s*(.+?)\s*$" | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value.Trim('"').Trim("'") }
    return $Default
}

function Set-EnvVal([string]$Key, [string]$Val) {
    $content = Get-Content $EnvFile
    if ($content -match "^\s*$Key\s*=") {
        $content -replace "^\s*$Key\s*=.*", "$Key=$Val" | Set-Content $EnvFile -Encoding utf8
    } else {
        Add-Content $EnvFile "$Key=$Val" -Encoding utf8
    }
}

function Get-Port { [int](Get-EnvVal "NINFER_PORT" "3400") }

function Test-Serving {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$(Get-Port)/health" -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
        return $r.StatusCode -eq 200
    } catch { return $false }
}

function Get-State {
    $s = docker inspect --format '{{.State.Status}}' $Container 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $s) { return "absent" }
    return $s.Trim()
}

function Show-Vram {
    $q = nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader 2>$null
    if ($q) { Write-Host ("  VRAM        : " + ($q -join "")) }
}

function Wait-Serving([int]$TimeoutSec = 360) {
    # Cold-loading ~19 GiB of weights into VRAM takes ~70 s; allow generously.
    Write-Host "  waiting for the model to load ..." -NoNewline
    $t = 0
    while ($t -lt $TimeoutSec) {
        if (Test-Serving) { Write-Host " serving." -ForegroundColor Green; return $true }
        if ((Get-State) -eq "restarting") {
            Write-Host ""
            Write-Host "  CRASH LOOP. Last log lines:" -ForegroundColor Red
            docker logs --tail 12 $Container 2>&1 | ForEach-Object { Write-Host "    $_" }
            Write-Host "  Most likely: the artifact named by NINFER_ARTIFACT is missing, or" -ForegroundColor Yellow
            Write-Host "  something else on the GPU is holding the VRAM it needs." -ForegroundColor Yellow
            return $false
        }
        Start-Sleep -Seconds 5
        $t += 5
        Write-Host "." -NoNewline
    }
    Write-Host ""
    Write-Host "  did not begin serving within $TimeoutSec s." -ForegroundColor Red
    return $false
}

function Invoke-Compose([string[]]$ComposeArgs) {
    Push-Location $Dir
    try { & docker compose @ComposeArgs 2>&1 | ForEach-Object { Write-Host "  $_" } }
    finally { Pop-Location }
}

switch ($Action.ToLower()) {

  "status" {
    $state   = Get-State
    $serving = Test-Serving
    Write-Host ""
    Write-Host "NInfer chat engine" -ForegroundColor Cyan
    if ($serving)                 { $col = "Green";  $txt = "SERVING" }
    elseif ($state -eq "running") { $col = "Yellow"; $txt = "running, not serving yet (still loading?)" }
    else                          { $col = "Red";    $txt = "STOPPED ($state)" }
    Write-Host ("  State       : " + $txt) -ForegroundColor $col
    Write-Host ("  Artifact    : " + (Get-EnvVal "NINFER_ARTIFACT" "?"))
    Write-Host ("  Context     : " + (Get-EnvVal "NINFER_MAX_CONTEXT" "?") + " tokens x " + (Get-EnvVal "NINFER_MAX_CONCURRENCY" "?") + " slot(s)")
    Write-Host ("  Speculative : mtp, draft-tokens " + (Get-EnvVal "NINFER_DRAFT_TOKENS" "?"))
    Write-Host ("  KV dtype    : " + (Get-EnvVal "NINFER_KV_DTYPE" "bf16"))
    Write-Host ("  Endpoint    : http://127.0.0.1:" + (Get-Port) + "/v1")
    Show-Vram
    if ($serving) {
      # Recent decode rates straight from the engine's own counter, not wall clock.
      $rates = docker logs --tail 400 $Container 2>&1 |
               Select-String -Pattern 'decode=([0-9.]+)tok/s' -AllMatches |
               ForEach-Object { $_.Matches } | ForEach-Object { [double]$_.Groups[1].Value }
      if ($rates -and @($rates).Count -gt 0) {
        $last = @($rates) | Select-Object -Last 10
        $avg  = ($last | Measure-Object -Average).Average
        Write-Host ("  Decode      : {0:N1} tok/s (mean of last {1} requests)" -f $avg, @($last).Count)
      }
    }
    if (Get-Process -Name "LM Studio" -ErrorAction SilentlyContinue) {
      Write-Host ""
      Write-Host "  NOTE: LM Studio is running. If it has a model loaded it is competing for" -ForegroundColor Yellow
      Write-Host "  VRAM -- only one engine's weights fit on this card." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  verbs: start | stop | restart | parity | context <n> | artifact <nvfp4|groupwise> | logs | health"
    Write-Host ""
  }

  "stop" {
    Write-Host "Evicting the model (frees its VRAM) ..." -ForegroundColor Cyan
    Invoke-Compose @("down")
    Show-Vram
    Write-Host "Stopped. Hermes has no chat model until you 'start' again." -ForegroundColor Yellow
  }

  "start" {
    Write-Host "Loading the model ..." -ForegroundColor Cyan
    Invoke-Compose @("up","-d")
    if (Wait-Serving) { Show-Vram }
  }

  "restart" {
    Invoke-Compose @("down")
    Invoke-Compose @("up","-d")
    if (Wait-Serving) { Show-Vram }
  }

  "parity" {
    Write-Host "Evicting the model to free the GPU for the embedding parity gate ..." -ForegroundColor Cyan
    Invoke-Compose @("down")
    Show-Vram
    Write-Host ""
    Write-Host "Now, by hand:" -ForegroundColor Cyan
    Write-Host "  1. Start LM Studio and load  text-embedding-nomic-embed-text-v1.5"
    Write-Host "  2. Run the gate (one line):"
    Write-Host "     docker exec vigil-mcp-server npx tsx scripts/verify-embedding-parity.ts --baseline http://host.docker.internal:1234/v1 --candidate http://text-embedder:3300/v1 --auto-ctx"
    Write-Host "     Expect worst gating cosine 1.000000 and exit 0."
    Write-Host "     ~0.98 means the embedder fell back to CPU and NEW WRITES ARE LANDING IN"
    Write-Host "     THE WRONG VECTOR SPACE. Exit 2 means nothing was measured -- not a pass."
    Write-Host "  3. Quit LM Studio, then:  .\VH-Model.ps1 start"
    Write-Host ""
  }

  "context" {
    if (-not $Value) {
      Write-Host "Usage: .\VH-Model.ps1 context <tokens>    e.g. 131072" -ForegroundColor Red
      Write-Host "Measured on this host (nvfp4, 1 slot): decode is FLAT across context length,"
      Write-Host "so this is a VRAM decision only. With int8 KV: 128k leaves ~4.0 GiB free,"
      Write-Host "192k leaves ~1.8 GiB. With bf16 KV, 128k leaves only ~0.3 GiB -- avoid."
      exit 1
    }
    Write-Host ("Setting max-context to " + $Value + " and reloading ...") -ForegroundColor Cyan
    Set-EnvVal "NINFER_MAX_CONTEXT" $Value
    Invoke-Compose @("up","-d")
    if (Wait-Serving) {
      Show-Vram
      # The failure mode to catch: if VRAM is short, --kv-capacity auto resolves FEWER
      # pages instead of refusing to start, so you silently get less context than asked.
      $kv = docker logs $Container 2>&1 | Select-String -Pattern "KV capacity auto resolved" | Select-Object -Last 1
      if ($kv) {
        $i = $kv.Line.IndexOf("KV capacity")
        Write-Host ("  " + $kv.Line.Substring($i))
      }
      Write-Host "  Check that pages=N/N match. If they differ, VRAM was short and the cache" -ForegroundColor Yellow
      Write-Host "  was silently downsized rather than refusing to start." -ForegroundColor Yellow
    }
  }

  "artifact" {
    $map = @{ "nvfp4" = "qwen3_8_27b_nvfp4.ninfer"; "groupwise" = "qwen3_8_27b.ninfer" }
    if (-not $Value -or -not $map.ContainsKey($Value.ToLower())) {
      Write-Host "Usage: .\VH-Model.ps1 artifact <nvfp4|groupwise>" -ForegroundColor Red
      Write-Host "  nvfp4      20.02 GiB, ~183 tok/s   (current default)"
      Write-Host "  groupwise  16.96 GiB, ~166 tok/s, ~3 GiB more VRAM headroom"
      exit 1
    }
    $file = $map[$Value.ToLower()]
    $path = Join-Path (Get-EnvVal "NINFER_MODELS_DIR" (Join-Path $env:USERPROFILE ".ninfer\models")) $file
    if (-not (Test-Path -LiteralPath $path)) {
      Write-Host "Artifact not on disk: $path" -ForegroundColor Red
      exit 1
    }
    Write-Host ("Switching to " + $file + " and reloading ...") -ForegroundColor Cyan
    Set-EnvVal "NINFER_ARTIFACT" $file
    Invoke-Compose @("up","-d")
    if (Wait-Serving) {
      Show-Vram
      Write-Host "  NOTE: draft-tokens tuning does NOT transfer between artifacts." -ForegroundColor Yellow
      Write-Host "  Measured optimum: nvfp4 -> 4;  groupwise -> 2..4 (flat)." -ForegroundColor Yellow
      Write-Host "  Re-check with bench\bench.sh after switching." -ForegroundColor Yellow
    }
  }

  "logs" { docker logs --tail 60 -f $Container }

  "health" {
    $sh = Join-Path $Dir "tools\check-collapse.sh"
    if (Test-Path $sh) { & bash $sh } else { Write-Host "watchdog not found at $sh" -ForegroundColor Red }
  }

  default {
    Write-Host ("Unknown action '" + $Action + "'.") -ForegroundColor Red
    Write-Host "verbs: status | start | stop | restart | parity | context <n> | artifact <nvfp4|groupwise> | logs | health"
    exit 1
  }
}
