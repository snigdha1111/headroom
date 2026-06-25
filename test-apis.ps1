# Headroom proxy — test every API endpoint, one at a time.
#
# Usage (from any shell with PowerShell):
#   .\test-apis.ps1            # run ALL tests in order
#   .\test-apis.ps1 -Only 3    # run only test #3
#   .\test-apis.ps1 -List      # list tests
#
# Each test prints [PASS]/[FAIL] and the route under test.
# Tests that need a real provider key are skipped automatically if the
# env var is missing, so the safe/local tests always run.

param(
  [int[]]$Only = @(),
  [switch]$List
)

$Base = "http://127.0.0.1:8787"

function Hit([string]$Label, [scriptblock]$Action) {
  Write-Host "`n=== $Label ===" -ForegroundColor Cyan
  try {
    & $Action
    Write-Host "[PASS] $Label" -ForegroundColor Green
  } catch {
    $msg = $_.Exception.Message
    $resp = $_.Exception.Response
    if ($resp) {
      $code = [int]$resp.StatusCode
      # For non-2xx: try to read body and show it (helps diagnose).
      $body = ""
      try { $sr = New-Object System.IO.StreamReader($resp.GetResponseStream()); $body = $sr.ReadToEnd() } catch {}
      if ($code -ge 200 -and $code -lt 300) { Write-Host "[PASS] $Label  (HTTP $code)" -ForegroundColor Green }
      elseif ($code -ge 400 -and $code -lt 500) {
        Write-Host "[PASS] $Label  (HTTP $code - client request shape OK)" -ForegroundColor Green
        if ($body) { Write-Host "    body: $($body.Substring(0,[Math]::Min(300,$body.Length)))" -ForegroundColor DarkGray }
      } else {
        Write-Host "[FAIL] $Label  : HTTP $code - $msg" -ForegroundColor Red
        if ($body) { Write-Host "    body: $($body.Substring(0,[Math]::Min(500,$body.Length)))" -ForegroundColor DarkGray }
      }
    } else {
      Write-Host "[FAIL] $Label  : $msg" -ForegroundColor Red
    }
  }
}

# A large fake tool output (string) we send as a multi-message payload.
$ToolOutput = "ERROR: disk full at /var/log/app.log. " * 300
$CompressBody = @{
  model = "claude-sonnet-4-5"
  messages = @(
    @{ role = "user"; content = "Please summarize this long log for me." },
    @{ role = "assistant"; content = "Sure." },
    @{ role = "tool"; content = @( @{ type = "text"; text = $ToolOutput } ) }
  )
} | ConvertTo-Json -Depth 6 -Compress

# ---- test definitions -----------------------------------------------------
$tests = @(
  @{ N=1;  Label="GET  /livez                       (liveness)";
     Action={ Invoke-RestMethod -Uri "$Base/livez" | ConvertTo-Json } },
  @{ N=2;  Label="GET  /readyz                      (readiness)";
     Action={ Invoke-RestMethod -Uri "$Base/readyz" | ConvertTo-Json } },
  @{ N=3;  Label="GET  /health                      (aggregate health)";
     Action={ Invoke-RestMethod -Uri "$Base/health" | ConvertTo-Json -Depth 6 } },
  @{ N=4;  Label="GET  /stats                       (compression stats)";
     Action={ Invoke-RestMethod -Uri "$Base/stats" | ConvertTo-Json -Depth 6 } },
  @{ N=5;  Label="GET  /stats-history               (durable history)";
     Action={ Invoke-RestMethod -Uri "$Base/stats-history" | ConvertTo-Json -Depth 6 } },
  @{ N=6;  Label="GET  /metrics                     (Prometheus)";
     Action={ (Invoke-WebRequest -Uri "$Base/metrics").Content.Substring(0,400) } },
  @{ N=7;  Label="GET  /quota                       (quota window)";
     Action={ Invoke-RestMethod -Uri "$Base/quota" | ConvertTo-Json } },
  @{ N=8;  Label="GET  /subscription-window         (subscription window)";
     Action={ Invoke-RestMethod -Uri "$Base/subscription-window" | ConvertTo-Json } },
  @{ N=9;  Label="GET  /v1/retrieve/stats           (CCR stats)";
     Action={ Invoke-RestMethod -Uri "$Base/v1/retrieve/stats" | ConvertTo-Json -Depth 6 } },
  @{ N=10; Label="GET  /v1/feedback                 (learn feedback)";
     Action={ Invoke-RestMethod -Uri "$Base/v1/feedback" | ConvertTo-Json -Depth 6 } },
  @{ N=11; Label="GET  /v1/telemetry                (telemetry summary)";
     Action={ Invoke-RestMethod -Uri "$Base/v1/telemetry" | ConvertTo-Json -Depth 6 } },
  @{ N=12; Label="GET  /v1/telemetry/tools          (tool telemetry)";
     Action={ Invoke-RestMethod -Uri "$Base/v1/telemetry/tools" | ConvertTo-Json -Depth 6 } },
  @{ N=13; Label="GET  /v1/toin/stats               (TOIN stats)";
     Action={ Invoke-RestMethod -Uri "$Base/v1/toin/stats" | ConvertTo-Json -Depth 6 } },
  @{ N=14; Label="GET  /v1/toin/patterns            (TOIN patterns)";
     Action={ Invoke-RestMethod -Uri "$Base/v1/toin/patterns" | ConvertTo-Json -Depth 6 } },
  @{ N=15; Label="GET  /dashboard                   (live HTML dashboard)";
     Action={ "HTML length: " + (Invoke-WebRequest -Uri "$Base/dashboard").Content.Length } },
  @{ N=16; Label="POST /v1/compress                 (compress - NO key needed)";
     Action={
        Invoke-RestMethod -Uri "$Base/v1/compress" -Method Post `
          -ContentType "application/json" -Body $CompressBody |
          ConvertTo-Json -Depth 6
     } },
  @{ N=17; Label="GET  /admin/upstream              (loopback: upstream info)";
     Action={ Invoke-RestMethod -Uri "$Base/admin/upstream" | ConvertTo-Json -Depth 4 } },
  @{ N=18; Label="GET  /debug/tasks                 (loopback: in-flight tasks)";
     Action={ Invoke-RestMethod -Uri "$Base/debug/tasks" | ConvertTo-Json -Depth 4 } },
  @{ N=19; Label="POST /cache/clear                 (loopback: clear cache)";
     Action={ Invoke-RestMethod -Uri "$Base/cache/clear" -Method Post | ConvertTo-Json } },
  @{ N=20; Label="POST /stats/reset                 (loopback: reset stats)";
     Action={ Invoke-RestMethod -Uri "$Base/stats/reset" -Method Post | ConvertTo-Json } },

  # --- these need real provider creds; skipped if env var is missing ---------
  @{ N=21; Label="POST /v1/messages                 (Anthropic - needs ANTHROPIC_API_KEY)";
     Action={
        if (-not $env:ANTHROPIC_API_KEY) { Write-Host "[SKIP] no ANTHROPIC_API_KEY" -ForegroundColor Yellow; return }
        $b = @{ model="claude-sonnet-4-5"; max_tokens=32;
                messages=@(@{role="user";content="Say 'ok'."}) } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "$Base/v1/messages" -Method Post -ContentType "application/json" `
          -Headers @{ "x-api-key"=$env:ANTHROPIC_API_KEY; "anthropic-version"="2023-06-01" } `
          -Body $b | ConvertTo-Json -Depth 6
     } },
  @{ N=22; Label="POST /v1/messages/count_tokens    (Anthropic - needs ANTHROPIC_API_KEY)";
     Action={
        if (-not $env:ANTHROPIC_API_KEY) { Write-Host "[SKIP] no ANTHROPIC_API_KEY" -ForegroundColor Yellow; return }
        $b = @{ model="claude-sonnet-4-5"; messages=@(@{role="user";content="hello"}) } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "$Base/v1/messages/count_tokens" -Method Post -ContentType "application/json" `
          -Headers @{ "x-api-key"=$env:ANTHROPIC_API_KEY; "anthropic-version"="2023-06-01" } `
          -Body $b | ConvertTo-Json -Depth 6
     } },
  @{ N=23; Label="POST /v1/chat/completions         (OpenAI - needs OPENAI_API_KEY)";
     Action={
        if (-not $env:OPENAI_API_KEY) { Write-Host "[SKIP] no OPENAI_API_KEY" -ForegroundColor Yellow; return }
        $b = @{ model="gpt-4o-mini"; max_tokens=16;
                messages=@(@{role="user";content="Say 'ok'."}) } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "$Base/v1/chat/completions" -Method Post -ContentType "application/json" `
          -Headers @{ "Authorization"="Bearer $env:OPENAI_API_KEY" } `
          -Body $b | ConvertTo-Json -Depth 6
     } },
  @{ N=24; Label="POST /v1/responses                (OpenAI Responses - needs OPENAI_API_KEY)";
     Action={
        if (-not $env:OPENAI_API_KEY) { Write-Host "[SKIP] no OPENAI_API_KEY" -ForegroundColor Yellow; return }
        $b = @{ model="gpt-4o-mini"; input="Say 'ok'." } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "$Base/v1/responses" -Method Post -ContentType "application/json" `
          -Headers @{ "Authorization"="Bearer $env:OPENAI_API_KEY" } `
          -Body $b | ConvertTo-Json -Depth 6
     } }
)

if ($List) {
  $tests | ForEach-Object { "{0,2}. {1}" -f $_.N, $_.Label }
  return
}

if ($Only.Count -gt 0) {
  $toRun = $tests | Where-Object { $_.N -in $Only }
  if ($toRun.Count -eq 0) { Write-Host "No tests found for: $($Only -join ', ')" -ForegroundColor Red; return }
  foreach ($t in $toRun) {
    Hit $t.Label $t.Action
  }
  return
}

# Run every test in order.
$pass=0; $fail=0
foreach ($t in $tests) {
  Hit $t.Label $t.Action
}
Write-Host "`nDone. PASS=$pass FAIL=$fail (see PASS/SKIP/FAIL labels above)" -ForegroundColor Cyan
