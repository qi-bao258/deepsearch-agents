<#
.SYNOPSIS
    启动「DepthSearch」基础设施（MySQL 教学库）。

.DESCRIPTION
    本项目与典型多容器项目的关键差异：**MySQL 是可选的**。

    - 后端 `/health/ready` 只校验 LLM 配置（OPENAI_API_KEY / OPENAI_BASE_URL /
      LLM_QWEN_MAX），不探测 MySQL。
    - MySQL 仅在 Agent 调用 `db_tools`（数据库查询助手）时才被访问。

    因此本脚本默认以「非阻塞」方式工作：容器起不来只警告，不中止后续启动。
    若需要严格保证 MySQL 可用（例如要演示数据库查询助手），加 -Strict。

.PARAMETER Strict
    MySQL 未就绪时抛错中止。适合需要完整演示 db_tools 的场景。

.PARAMETER TimeoutSeconds
    等待 MySQL 就绪的最长秒数，默认 120。

.EXAMPLE
    .\scripts\start-infra.ps1
    启动 MySQL，失败仅警告。

.EXAMPLE
    .\scripts\start-infra.ps1 -Strict
    启动 MySQL，失败即中止。
#>

[CmdletBinding()]
param(
    [switch]$Strict,
    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ComposeFile = Join-Path $ProjectRoot 'docker\docker-compose.yaml'
$EnvFile = Join-Path $ProjectRoot '.env'

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
    <#
      快速 TCP 探测。不用 Test-NetConnection —— 它先发 ICMP 再建 TCP，
      每次约 1 秒且进度输出污染终端。
    #>
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

function Invoke-NativeCapture {
    <#
      执行原生命令并只返回退出码。

      $ErrorActionPreference='Stop' 下，原生命令写到 stderr 的内容会被
      PowerShell 包装成终止性 NativeCommandError，优先于 $LASTEXITCODE 判定，
      导致探测分支直接崩溃。这里临时降级错误策略规避。
    #>
    param([scriptblock]$Action)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Action 2>&1 | Out-Null
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
}

# ---------------------------------------------------------------------------

Write-Step "检查 Docker 引擎"

$dockerReady = (Invoke-NativeCapture { docker info --format '{{.ServerVersion}}' }) -eq 0

if (-not $dockerReady) {
    Write-Warn2 "Docker 引擎未运行，尝试启动 Docker Desktop…"
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\Docker Desktop.exe'),
        'C:\Program Files\Docker\Docker\Docker Desktop.exe'
    )
    $exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($exe) {
        Start-Process -FilePath $exe | Out-Null
        $deadline = (Get-Date).AddSeconds(180)
        while ((Get-Date) -lt $deadline) {
            if ((Invoke-NativeCapture { docker info --format '{{.ServerVersion}}' }) -eq 0) {
                $dockerReady = $true
                break
            }
            Start-Sleep -Seconds 5
        }
    }
}

if ($dockerReady) {
    Write-Ok "Docker 引擎已就绪"
} else {
    Write-Warn2 "Docker 引擎不可用，跳过 MySQL 启动"
    if ($Strict) { throw "MySQL 未启动（-Strict 模式）" }
    Write-Warn2 "后端仍可启动：/health/ready 不依赖 MySQL；仅 db_tools 不可用"
    exit 0
}

# ---------------------------------------------------------------------------

Write-Step "启动 MySQL 容器"

$composeArgs = @('compose', '-f', $ComposeFile, 'up', '-d')
if (Test-Path $EnvFile) { $composeArgs += @('--env-file', $EnvFile) }

$code = Invoke-NativeCapture { & docker @composeArgs }

if ($code -ne 0) {
    Write-Warn2 "docker compose up 失败（退出码 $code）"
    if ($Strict) { throw "MySQL 启动失败（-Strict 模式）" }
    Write-Warn2 "继续后续流程（后端不依赖 MySQL 探活）"
    exit 0
}
Write-Ok "容器已启动"

# 端口取自 .env 的 MYSQL_PORT，默认 3308（避开本机 3306）
$mySqlPort = 3308
if (Test-Path $EnvFile) {
    $portLine = Get-Content $EnvFile -Encoding utf8 |
                Where-Object { $_ -match '^\s*MYSQL_PORT\s*=' } |
                Select-Object -First 1
    if ($portLine) { $mySqlPort = [int](($portLine -split '=', 2)[1].Trim()) }
}
Write-Host "    期望端口：$mySqlPort" -ForegroundColor Gray

Write-Step "等待 MySQL 就绪（最长 $TimeoutSeconds 秒）"
Write-Host "    等待 127.0.0.1:$mySqlPort …" -NoNewline
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$ready = $false
while ((Get-Date) -lt $deadline) {
    if (Test-TcpPort -Port $mySqlPort) { $ready = $true; break }
    Write-Host "." -NoNewline -ForegroundColor DarkGray
    Start-Sleep -Seconds 3
}

Write-Host ""
if ($ready) {
    Write-Ok "MySQL 已就绪（127.0.0.1:$mySqlPort，库：deepsearch_db）"
    exit 0
} else {
    Write-Warn2 "MySQL 在 $TimeoutSeconds 秒内未就绪"
    if ($Strict) { throw "MySQL 未就绪（-Strict 模式）" }
    Write-Warn2 "继续后续流程；如需排查：docker logs deepsearch-mysql --tail=50"
    exit 0
}
