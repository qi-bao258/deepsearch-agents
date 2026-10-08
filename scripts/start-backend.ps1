<#
.SYNOPSIS
    启动「DepthSearch」FastAPI 后端。

.DESCRIPTION
    启动前完成三项校验，再拉起 uvicorn 并等待就绪探针：

      1. 虚拟环境与 python-dotenv 是否可用
      2. .env 中 LLM 三项配置是否齐备
         —— 这三项正是 /health/ready 的判定依据，缺任一项就绪探针必返 503
      3. 端口是否被占用

    关于环境变量的加载时机：本项目通过 app/agent/llm.py 里的
    load_dotenv(find_dotenv()) 载入 .env，该调用在模块导入时执行。
    导入 app.api.server 会经依赖链触发它，因此 uvicorn 起来后
    就绪探针能读到这些变量，无需在外层脚本重复注入。

.PARAMETER Port
    后端端口，默认 8001（与 frontend/.env.local 的 VITE_API_BASE_URL 对应）。

.PARAMETER NoWait
    启动后不等待就绪探针，立即返回。

.EXAMPLE
    .\scripts\start-backend.ps1
    常规启动并等待就绪。

.EXAMPLE
    .\scripts\start-backend.ps1 -Port 8002
    改用 8002 端口（需同步修改 frontend/.env.local）。
#>

[CmdletBinding()]
param(
    [int]$Port = 8001,
    [switch]$NoWait
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host ">>> $Message" -ForegroundColor Cyan
}
function Write-Ok([string]$Message) {
    Write-Host "    [OK]   $Message" -ForegroundColor Green
}
function Write-Warn2([string]$Message) {
    Write-Host "    [WARN] $Message" -ForegroundColor Yellow
}

function Test-TcpPort {
    param(
        [string]$TargetHost = '127.0.0.1',
        [int]$Port,
        [int]$TimeoutMs = 1500
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# ---------------------------------------------------------------------------

Write-Step "步骤 1/3 · 校验运行环境"

$venvPython = Join-Path $ProjectRoot '.venv\Scripts\python.exe'
if (-not (Test-Path $venvPython)) {
    throw "找不到虚拟环境：$venvPython`n请先执行：uv sync"
}
Write-Ok "虚拟环境就绪"

Write-Step "步骤 2/3 · 校验 LLM 配置"

$envFile = Join-Path $ProjectRoot '.env'
if (-not (Test-Path $envFile)) {
    throw ".env 不存在。请复制 .env.example 并填入真实密钥。"
}

# 这三项即 /health/ready 的判定依据，缺任一项就绪探针必返 503
$requiredKeys = @('OPENAI_API_KEY', 'OPENAI_BASE_URL', 'LLM_QWEN_MAX')
$missing = @()
foreach ($key in $requiredKeys) {
    $line = Get-Content $envFile -Encoding utf8 |
            Where-Object { $_ -match "^\s*$key\s*=" } |
            Select-Object -First 1
    if (-not $line) {
        Write-Warn2 "$key 未配置"
        $missing += $key
        continue
    }
    $value = ($line -split '=', 2)[1].Trim()
    $isPlaceholder = ($value -eq '') -or ($value -match 'your|xxx|占位|placeholder')
    if ($isPlaceholder) {
        Write-Warn2 "$key 仍是占位值"
        $missing += $key
    } else {
        Write-Ok "$key 已配置"
    }
}

if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Warn2 "缺失配置：$($missing -join ', ')"
    throw ".env 配置不完整，就绪探针会返回 503，已中止启动。"
}

Write-Step "步骤 3/3 · 校验端口并启动"

if (Test-TcpPort -Port $Port) {
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    $pidInfo = if ($conn) { " (PID $($conn[0].OwningProcess))" } else { "" }
    throw "端口 $Port 已被占用$pidInfo。请先释放，或用 -Port 指定其它端口。"
}
Write-Ok "端口 $Port 空闲"

$uvicornArgs = @(
    '-m', 'uvicorn', 'app.api.server:app',
    '--host', '127.0.0.1', '--port', "$Port"
)

# 提示前端联动：前端通过 VITE_API_BASE_URL 直连后端，不走 Vite proxy
$feEnvFile = Join-Path $ProjectRoot 'frontend\.env.local'
if (Test-Path $feEnvFile) {
    $feBase = Get-Content $feEnvFile -Encoding utf8 |
              Where-Object { $_ -match 'VITE_API_BASE_URL' } |
              Select-Object -First 1
    if ($feBase -and ($feBase -notmatch ":$Port")) {
        Write-Warn2 "frontend/.env.local 的 $($feBase.Trim()) 与后端端口 $Port 不一致，前端会连不上"
    }
}

Write-Host "    命令：python -m uvicorn app.api.server:app --port $Port" -ForegroundColor Gray
Write-Host "    提示：日志输出在下方，Ctrl+C 停止。" -ForegroundColor DarkGray
Write-Host ""

# 用 System.Diagnostics.Process 直接启动，比 Start-Process -PassThru 更可靠
# （在非交互式/无窗口上下文里 Start-Process 可能拿不到进程句柄）
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $venvPython
$psi.Arguments = ($uvicornArgs | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
$psi.WorkingDirectory = $ProjectRoot
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $false
$psi.RedirectStandardError = $false

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi

$started = $proc.Start()
if (-not $started) { throw "无法启动后端进程。" }
Write-Host "    python 进程已启动 (PID $($proc.Id))" -ForegroundColor DarkGray

if ($NoWait) {
    Write-Ok "已在后台启动（未等待就绪）"
    exit 0
}

$healthUrl = "http://127.0.0.1:$Port/health"
$readyUrl = "http://127.0.0.1:$Port/health/ready"
$deadline = (Get-Date).AddSeconds(120)
$ready = $false

Write-Host "    等待就绪探针 $readyUrl …" -NoNewline
while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) {
        Write-Host ""
        throw "后端进程已退出（退出码 $($proc.ExitCode)）。请检查上方日志。"
    }
    if (Test-TcpPort -Port $Port) {
        try {
            $req = [System.Net.HttpWebRequest]::Create($readyUrl)
            $req.Timeout = 3000
            $resp = $req.GetResponse()
            $code = [int]$resp.StatusCode
            $body = (New-Object System.IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
            $resp.Close()
            if ($code -eq 200) {
                Write-Host " OK" -ForegroundColor Green
                $ready = $true
                break
            } else {
                Write-Host ""
                Write-Warn2 "就绪探针返回 $code：$body"
                Write-Host "    继续等待…" -NoNewline
            }
        } catch {
            # 端口已开但 HTTP 层还没就绪，属正常中间态
        }
    }
    Write-Host "." -NoNewline -ForegroundColor DarkGray
    Start-Sleep -Seconds 2
}

Write-Host ""
if ($ready) {
    Write-Host "后端已就绪。" -ForegroundColor Green
    Write-Host "  接口文档：http://127.0.0.1:$Port/docs" -ForegroundColor Gray
    Write-Host "  健康检查：$healthUrl" -ForegroundColor Gray
    Write-Host "  按 Ctrl+C 停止后端。" -ForegroundColor DarkGray
    Write-Host ""
    try {
        $proc.WaitForExit()
    } finally {
        if (-not $proc.HasExited) { $proc.Kill() }
    }
    exit 0
} else {
    Write-Warn2 "就绪探针在 120 秒内未返回 200。进程仍在运行，可手动确认："
    Write-Host "  curl http://127.0.0.1:$Port/health/ready" -ForegroundColor Gray
    exit 1
}
