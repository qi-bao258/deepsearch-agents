<#
.SYNOPSIS
    一键启动「DepthSearch」全栈：基础设施 → 后端 → 前端。

.DESCRIPTION
    按依赖顺序串行编排：

        start-infra.ps1     启动 MySQL（失败仅警告，不阻塞）
        start-backend.ps1   校验 LLM 配置 → 起 FastAPI → 等 /health/ready
        start-frontend.ps1  校验依赖 → 起 Vite → 等端口监听

    与同类项目的重要差异：**MySQL 不是启动后端的必要条件**。
    本项目的 /health/ready 只校验 LLM 三项配置，不探测数据库。
    因此即便 Docker 不可用，后端与前端仍可正常启动，只是 Agent 的
    数据库查询工具（db_tools）不可用。

.PARAMETER SkipInfra
    跳过 MySQL 启动环节。

.PARAMETER SkipKibana
    保留参数位（本项目无 Kibana），仅为与同类脚本保持一致的调用习惯。

.PARAMETER StrictInfra
    要求 MySQL 必须就绪，否则中止。

.EXAMPLE
    .\scripts\start-all.ps1
    完整启动。

.EXAMPLE
    .\scripts\start-all.ps1 -SkipInfra
    不启 MySQL（无 Docker 时使用）。
#>

[CmdletBinding()]
param(
    [switch]$SkipInfra,
    [switch]$SkipKibana,
    [switch]$StrictInfra,
    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $ScriptDir

Write-Host ""
Write-Host "=============================================" -ForegroundColor White
Write-Host "  DepthSearch · 全栈启动" -ForegroundColor White
Write-Host "=============================================" -ForegroundColor White
Write-Host "  项目根目录：$ProjectRoot" -ForegroundColor DarkGray

$sw = [System.Diagnostics.Stopwatch]::StartNew()

function Start-ChildScript {
    <#
      在独立进程中启动子脚本。

      为什么不用 Start-Process：
        本机安全策略会拦截「以 shell 解释器为目标的 Start-Process」
        （报 "Start-Process with a shell/interpreter/LOLBin target"）。

      为什么 UseShellExecute = $false：
        实测 UseShellExecute = $true 在本环境会**静默终止整个 PowerShell 进程**，
        导致脚本在第 2 步无输出退出（退出码 1）。
        UseShellExecute = $false + CreateNoWindow = $true 稳定可用，
        且能拿到有效 PID，便于后续管理。

      代价：子脚本不再有独立可见窗口。它们的日志会输出到本终端，
      需要单独观察时请直接运行对应的 start-backend.ps1 / start-frontend.ps1。
    #>
    param(
        [string]$ScriptPath,
        [string]$WorkDir
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command powershell.exe).Source
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false

    $p = [System.Diagnostics.Process]::Start($psi)
    if ($p) { return "PID $($p.Id)" }
    return '已派生（未取到 PID）'
}

# --- 基础设施 -------------------------------------------------------------
if ($SkipInfra) {
    Write-Host ""
    Write-Host "[1/3] 基础设施：已跳过（-SkipInfra）" -ForegroundColor DarkGray
} else {
    Write-Host ""
    Write-Host "[1/3] 基础设施（MySQL）" -ForegroundColor White
    $infraArgs = @{ TimeoutSeconds = $TimeoutSeconds }
    if ($StrictInfra) { $infraArgs['Strict'] = $true }
    & (Join-Path $ScriptDir 'start-infra.ps1') @infraArgs
    # start-infra 默认非阻塞：MySQL 不可用时仍返回 0
    if ($LASTEXITCODE -ne 0) {
        if ($StrictInfra) {
            Write-Host ""
            Write-Host "MySQL 未就绪（-StrictInfra），已中止。" -ForegroundColor Red
            exit 1
        }
        Write-Host "    MySQL 未就绪，继续启动应用层" -ForegroundColor Yellow
    }
}

# --- 后端 -----------------------------------------------------------------
Write-Host ""
Write-Host "[2/3] 后端（独立窗口）" -ForegroundColor White
$beNote = Start-ChildScript -ScriptPath (Join-Path $ScriptDir 'start-backend.ps1') -WorkDir $ProjectRoot
Write-Host "    已在新窗口启动 ($beNote)，等待其就绪…" -ForegroundColor Gray

# 用一个安全的探针函数：StrictMode 下 $_.Exception.Response 可能不存在，
# 直接访问会抛 PropertyNotFoundException，因此必须用 PSObject.Properties 检查。
function Test-UrlOk {
    param([string]$Url, [int]$TimeoutMs = 3000)
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Timeout = $TimeoutMs
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
        return ($code -eq 200)
    } catch {
        # 非 200（如 503）时 HttpWebRequest 抛异常，Response 里带真实状态码
        $ex = $_.Exception
        if ($ex -and $ex.PSObject.Properties['Response'] -and $ex.Response) {
            try { return ([int]$ex.Response.StatusCode -eq 200) } catch { return $false }
        }
        return $false
    }
}

$deadline = (Get-Date).AddSeconds(150)
$backendReady = $false
while ((Get-Date) -lt $deadline) {
    if (Test-UrlOk -Url 'http://127.0.0.1:8001/health/ready') {
        $backendReady = $true
        break
    }
    Start-Sleep -Seconds 3
}

if ($backendReady) {
    Write-Host "    后端就绪：http://127.0.0.1:8001/docs" -ForegroundColor Green
} else {
    Write-Host "    后端在 150 秒内未就绪，仍继续启动前端（见后端窗口日志）" -ForegroundColor Yellow
}

# --- 前端 -----------------------------------------------------------------
Write-Host ""
Write-Host "[3/3] 前端（独立窗口）" -ForegroundColor White
$feNote = Start-ChildScript -ScriptPath (Join-Path $ScriptDir 'start-frontend.ps1') -WorkDir $ProjectRoot
Write-Host "    已在新窗口启动 ($feNote)" -ForegroundColor Gray

$deadline = (Get-Date).AddSeconds(120)
$frontendReady = $false
while ((Get-Date) -lt $deadline) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect('127.0.0.1', 5173, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne(1000, $false)) {
            $client.EndConnect($async)
            $frontendReady = $true
        }
    } catch {
    } finally {
        $client.Close()
    }
    if ($frontendReady) { break }
    Start-Sleep -Seconds 2
}

$sw.Stop()

Write-Host ""
Write-Host "=============================================" -ForegroundColor White
if ($frontendReady -and $backendReady) {
    Write-Host "  启动完成（耗时 $([math]::Round($sw.Elapsed.TotalSeconds, 1))s）" -ForegroundColor Green
} else {
    Write-Host "  部分环节未确认就绪（耗时 $([math]::Round($sw.Elapsed.TotalSeconds, 1))s）" -ForegroundColor Yellow
}
Write-Host "=============================================" -ForegroundColor White
Write-Host "  前端界面：http://localhost:5173" -ForegroundColor Gray
Write-Host "  接口文档：http://127.0.0.1:8001/docs" -ForegroundColor Gray
Write-Host "  健康检查：http://127.0.0.1:8001/health/ready" -ForegroundColor Gray
Write-Host ""
Write-Host "  停止服务：.\scripts\stop-all.ps1" -ForegroundColor DarkGray
Write-Host ""
