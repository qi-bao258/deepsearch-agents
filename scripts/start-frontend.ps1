<#
.SYNOPSIS
    启动「DepthSearch」前端（Vite dev server）。

.DESCRIPTION
    启动前校验 Node.js、依赖完整性与后端代理配置，再拉起 Vite 并等待端口监听。

    关于包管理器：本项目的 frontend/package.json 声明
    `packageManager: pnpm@10.33.0`，而本机 pnpm 为 12.x，pnpm 会尝试下载
    声明版本并失败。因此本脚本**优先直接调用 node_modules 里的 vite**，
    必要时回退到 npm，不依赖 pnpm 的版本协商。

    另外，本项目前端通过 VITE_API_BASE_URL 直连后端（不走 Vite proxy），
    vite.config.ts 里的 proxy 配置实际上未被使用。因此后端端口必须与
    frontend/.env.local 一致，否则页面能打开但请求全部失败。

.PARAMETER Port
    前端端口，默认 5173。

.PARAMETER ForceReinstall
    强制用 npm 全量重装依赖。仅在链接自愈失败时才需要，且可能被
    本机沙箱的批量删除保护拦截，优先使用 -RepairLinks。

.PARAMETER RepairLinks
    启动前先运行 scripts\repair-node-links.py，自适应修复 node_modules
    里退化为空目录的 pnpm 链接（项目跨磁盘/路径迁移后的典型故障）。
    这是修复 "Cannot find module @rollup/rollup-win32-x64-msvc"、
    "You installed esbuild for another platform"、"Cannot find package
     ...@vitejs/plugin-react" 这类错误的推荐手段。

.PARAMETER NoRepair
    跳过自动链接自愈（默认会自动执行）。

.PARAMETER NoWait
    启动后不等待端口就绪，立即返回。

.EXAMPLE
    .\scripts\start-frontend.ps1
    常规启动并等待就绪。

.EXAMPLE
    .\scripts\start-frontend.ps1 -RepairLinks
    先修复链接再启动（依赖损坏时使用）。
#>

[CmdletBinding()]
param(
    [int]$Port = 5173,
    [switch]$ForceReinstall,
    [switch]$RepairLinks,
    [switch]$NoRepair,
    [switch]$NoWait
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$FrontendRoot = Join-Path $ProjectRoot 'frontend'

if (-not (Test-Path $FrontendRoot)) {
    throw "找不到前端目录：$FrontendRoot"
}

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

function Test-ViteUsable {
    <#
      判定 node_modules 里的 vite 是否真的可用。

      只看 .bin/vite.cmd 是否存在不够 —— pnpm 的 .bin 脚本通常硬编码了
      安装时的绝对路径，项目被移动后文件仍在但执行会失败。
      这里直接检查 vite.js 实体文件是否存在，更可靠。
    #>
    param([string]$FrontendRoot)
    $viteJs = Join-Path $FrontendRoot 'node_modules\vite\bin\vite.js'
    return (Test-Path $viteJs)
}

function Invoke-NodeLinkRepair {
    <#
      调用 scripts\repair-node-links.py 自愈 node_modules 链接。

      项目跨磁盘/路径迁移后，pnpm 的 junction 会退化为空目录。
      典型报错：
        Cannot find module @rollup/rollup-win32-x64-msvc
        You installed esbuild for another platform than the one you're currently using
        Cannot find package '...\@vitejs\plugin-react\index.js'
        SyntaxError: ... does not provide an export named 'default'
      这些都不是代码问题，而是链接损坏。
    #>
    param([string]$ProjectRoot)

    $repairScript = Join-Path $ProjectRoot 'scripts\repair-node-links.py'
    if (-not (Test-Path $repairScript)) {
        Write-Warn2 "未找到 scripts\repair-node-links.py，跳过链接自愈"
        return $false
    }

    # 优先用项目 venv 的 python，其次系统 python
    $python = Join-Path $ProjectRoot '.venv\Scripts\python.exe'
    if (-not (Test-Path $python)) {
        $pyCmd = Get-Command python -ErrorAction SilentlyContinue
        if (-not $pyCmd) {
            Write-Warn2 "未找到 Python，跳过链接自愈"
            return $false
        }
        $python = $pyCmd.Source
    }

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $env:PYTHONUTF8 = '1'
        & $python $repairScript
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return ($code -eq 0)
}

# ---------------------------------------------------------------------------

Write-Step "步骤 1/4 · 校验前端环境"

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { throw "未找到 Node.js。请安装 Node.js 18+ 后重试。" }
Write-Ok "node $(node --version)"

# 先做链接自愈（除非显式跳过）
if (-not $NoRepair -and -not $ForceReinstall) {
    Write-Step "步骤 2/4 · 自愈 node_modules 链接"

    if ($RepairLinks -or -not (Test-ViteUsable -FrontendRoot $FrontendRoot)) {
        if ($RepairLinks) {
            Write-Host "    指定了 -RepairLinks，强制修复" -ForegroundColor Gray
        } else {
            Write-Warn2 "node_modules 中的 vite 不完整，尝试自愈链接"
        }
        $null = Invoke-NodeLinkRepair -ProjectRoot $ProjectRoot
    } else {
        Write-Host "    运行链接自愈（无损坏则为空操作）…" -ForegroundColor Gray
        $null = Invoke-NodeLinkRepair -ProjectRoot $ProjectRoot
    }

    if (Test-ViteUsable -FrontendRoot $FrontendRoot) {
        Write-Ok "前端依赖就绪"
    } else {
        Write-Warn2 "自愈后仍未找到 node_modules\vite\bin\vite.js"
    }
} else {
    Write-Step "步骤 2/4 · 自愈 node_modules 链接（已跳过）"
}

$needInstall = $ForceReinstall -or (-not (Test-ViteUsable -FrontendRoot $FrontendRoot))

if ($needInstall) {
    if ($ForceReinstall) {
        Write-Warn2 "指定了 -ForceReinstall，将重装前端依赖"
    } else {
        Write-Warn2 "node_modules 中的 vite 不完整（可能是项目移动后符号链接失效）"
    }

    $npm = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $npm) { throw "未找到 npm，无法重装依赖。" }

    $nmPath = Join-Path $FrontendRoot 'node_modules'
    if (Test-Path $nmPath) {
        Write-Host "    删除现有 node_modules …" -ForegroundColor Gray
        try {
            # pnpm 建立的符号链接可能让 Remove-Item 失败，先改权限再删
            Get-ChildItem $nmPath -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.LinkType } |
                ForEach-Object { try { $_.Delete() } catch {} }
            Remove-Item $nmPath -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Warn2 "删除 node_modules 时出现异常：$($_.Exception.Message)"
        }
    }

    Write-Host "    执行 npm install（首次较慢）…" -ForegroundColor Gray
    Push-Location $FrontendRoot
    try {
        # npm 不读 packageManager 字段，因此可绕开 pnpm 的版本协商问题
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & npm install --no-fund --no-audit
            $npmExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prev
        }
        if ($npmExit -ne 0) { throw "npm install 失败（退出码 $npmExit）" }
    } finally {
        Pop-Location
    }
    Write-Ok "依赖已安装"

    if (-not (Test-ViteUsable -FrontendRoot $FrontendRoot)) {
        throw "安装后仍未找到 node_modules\vite\bin\vite.js，请手动检查依赖。"
    }
} else {
    Write-Ok "前端依赖就绪"
}

Write-Step "步骤 3/4 · 检查后端代理配置"

# 前端通过 VITE_API_BASE_URL 直连后端，不走 Vite proxy
$feEnvLocal = Join-Path $FrontendRoot '.env.local'
$apiBase = $null
if (Test-Path $feEnvLocal) {
    $line = Get-Content $feEnvLocal -Encoding utf8 |
            Where-Object { $_ -match 'VITE_API_BASE_URL' } |
            Select-Object -First 1
    if ($line) {
        $apiBase = ($line -split '=', 2)[1].Trim()
        Write-Ok "VITE_API_BASE_URL = $apiBase"
    }
} else {
    Write-Warn2 "frontend/.env.local 不存在，前端将回落到默认 http://localhost:8000"
}

if ($apiBase -and ($apiBase -match ':(\d+)')) {
    $backendPort = [int]$Matches[1]
    if (Test-TcpPort -Port $backendPort) {
        Write-Ok "后端端口 $backendPort 可达"
    } else {
        Write-Warn2 "后端端口 $backendPort 不可达 —— 请先运行 start-backend.ps1"
    }
}

Write-Step "步骤 4/4 · 启动 Vite"

if (Test-TcpPort -Port $Port) {
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    $pidInfo = if ($conn) { " (PID $($conn[0].OwningProcess))" } else { "" }
    throw "端口 $Port 已被占用$pidInfo。请先释放，或用 -Port 指定其它端口。"
}
Write-Ok "端口 $Port 空闲"

$viteJs = Join-Path $FrontendRoot 'node_modules\vite\bin\vite.js'
$nodeExe = (Get-Command node).Source
$viteArgs = @($viteJs, '--port', "$Port", '--host', '127.0.0.1')

Write-Host "    命令：node node_modules\vite\bin\vite.js --port $Port" -ForegroundColor Gray
Write-Host "    提示：日志输出在下方，Ctrl+C 停止。" -ForegroundColor DarkGray
Write-Host ""

# 用 System.Diagnostics.Process 直接启动，比 Start-Process -PassThru 更可靠
# （在非交互式/无窗口上下文里 Start-Process 可能拿不到句柄）
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $nodeExe
$psi.Arguments = ($viteArgs | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
$psi.WorkingDirectory = $FrontendRoot
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $false
$psi.RedirectStandardError = $false

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi

$started = $proc.Start()
if (-not $started) {
    throw "无法启动 node 进程。请确认 node 在 PATH 中。"
}
Write-Host "    node 进程已启动 (PID $($proc.Id))" -ForegroundColor DarkGray

if ($NoWait) {
    Write-Ok "已在后台启动（未等待就绪）"
    exit 0
}

$deadline = (Get-Date).AddSeconds(90)
$ready = $false

Write-Host "    等待 Vite 监听 $Port …" -NoNewline
while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) {
        Write-Host ""
        throw "前端进程已退出（退出码 $($proc.ExitCode)）。请检查上方日志。"
    }
    if (Test-TcpPort -Port $Port) {
        Write-Host " OK" -ForegroundColor Green
        $ready = $true
        break
    }
    Write-Host "." -NoNewline -ForegroundColor DarkGray
    Start-Sleep -Seconds 2
}

Write-Host ""
if ($ready) {
    Write-Host "前端已就绪。" -ForegroundColor Green
    Write-Host "  访问地址：http://localhost:$Port" -ForegroundColor Gray
    Write-Host "  后端 API：$(if ($apiBase) { $apiBase } else { 'http://localhost:8000' })" -ForegroundColor Gray
    Write-Host "  按 Ctrl+C 停止前端。" -ForegroundColor DarkGray
    Write-Host ""
    # 保持前台运行，转发 Ctrl+C；进程随本终端退出而结束
    try {
        $proc.WaitForExit()
    } finally {
        if (-not $proc.HasExited) { $proc.Kill() }
    }
    exit 0
} else {
    Write-Warn2 "Vite 未在 90 秒内监听 $Port。进程仍在运行，请检查上方日志。"
    exit 1
}

