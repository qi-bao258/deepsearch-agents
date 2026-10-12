<#
    深度研搜 · 一键启动（容器版）

    双击即可运行。流程：
      1. 确保 Docker Desktop 引擎运行（未运行则自动拉起并等待）
      2. docker compose up -d  启动全部容器（MySQL + 后端 + 前端）
      3. 等待后端 /health/ready 返回 200
      4. 打开浏览器

    与旧版（宿主机进程）的关键区别：
    后端与前端也在容器内运行，由 Docker daemon 托管，不受终端会话
    生命周期影响。因此启动完成后可以直接关掉本窗口，服务照常运行。

    停止服务：运行「停止深度研搜.ps1」
#>

$ErrorActionPreference = 'Continue'

$ProjectRoot = $PSScriptRoot
$DockerDir   = Join-Path $ProjectRoot 'docker'
$EnvFile     = Join-Path $ProjectRoot '.env'
$DockerDesktop = Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\Docker Desktop.exe'

# compose 文件组合：基础设施 + 网络 + 应用
$ComposeFiles = @(
    '-f', 'docker-compose.yaml',
    '-f', 'docker-compose.net.yaml',
    '-f', 'docker-compose.app.yaml'
)

$FrontendUrl = 'http://localhost:5174'
$ReadyUrl    = 'http://127.0.0.1:8001/health/ready'
$DocsUrl     = 'http://127.0.0.1:8001/docs'

# --- 输出辅助 -------------------------------------------------------------
function Write-Head([string]$t) {
    Write-Host ''
    Write-Host '=============================================' -ForegroundColor White
    Write-Host "  $t" -ForegroundColor White
    Write-Host '=============================================' -ForegroundColor White
}
function Write-Step([string]$t) { Write-Host ''; Write-Host ">>> $t" -ForegroundColor Cyan }
function Write-Ok([string]$t)   { Write-Host "    [OK]   $t" -ForegroundColor Green }
function Write-Warn2([string]$t){ Write-Host "    [WARN] $t" -ForegroundColor Yellow }
function Write-Info([string]$t) { Write-Host "    $t" -ForegroundColor Gray }

function Stop-WithPause([string]$msg) {
    if ($msg) { Write-Warn2 $msg }
    Write-Host ''
    Read-Host '按回车退出'
    exit 1
}

# --- 基础探测 -------------------------------------------------------------

# 静默执行 docker 命令，只返回退出码是否成功（避免 docker 往 stderr 写进度被当成错误）
# 注意：参数名不能用 $Args —— 它是 PowerShell 自动变量，会遮蔽同名自定义参数，
# 导致调用方传进来的数组变空（实测 all=compose，子命令丢失）。
function Invoke-DockerQuiet {
    param([string[]]$DockerArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & docker @DockerArgs 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Test-Engine {
    return (Invoke-DockerQuiet @('info', '--format', '{{.ServerVersion}}'))
}

function Get-EngineVersion {
    try {
        $v = & docker info --format '{{.ServerVersion}}' 2>$null
        if ($LASTEXITCODE -eq 0) { return "$v".Trim() }
    } catch { }
    return ''
}

function Test-Port([int]$Port, [int]$TimeoutMs = 1500) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $a = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $a.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $c.EndConnect($a); return $true
    } catch { return $false } finally { $c.Close() }
}

# 探测 HTTP 200，显式禁用代理（本机环境存在 HTTP_PROXY，会把 127.0.0.1 请求劫持导致 502）
function Test-Http200([string]$Url, [int]$TimeoutMs = 5000) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $req.Proxy = $null            # 关键：绕过代理直连
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
        return ($code -eq 200)
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $prev
    }
}

# compose 统一入口（工作目录固定在 docker/，显式指定 --env-file）
function Invoke-Compose {
    # 参数名不能用 $Args（PowerShell 自动变量，会遮蔽自定义参数导致数组变空）
    param([string[]]$ComposeArgs, [switch]$Quiet)
    $all = @('compose', '--env-file', $EnvFile) + $ComposeFiles + $ComposeArgs
    Push-Location $DockerDir
    try {
        if ($Quiet) {
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $null = & docker @all 2>&1
                return ($LASTEXITCODE -eq 0)
            } finally { $ErrorActionPreference = $prev }
        } else {
            & docker @all
            return ($LASTEXITCODE -eq 0)
        }
    } finally {
        Pop-Location
    }
}

# --- 前置检查 -------------------------------------------------------------
Write-Head '深度研搜 · 一键启动（容器版）'

if (-not (Test-Path $DockerDir)) {
    Stop-WithPause "未找到 docker 目录：$DockerDir"
}
if (-not (Test-Path (Join-Path $DockerDir 'docker-compose.app.yaml'))) {
    Stop-WithPause '未找到 docker-compose.app.yaml，项目文件可能不完整。'
}
if (-not (Test-Path $EnvFile)) {
    Stop-WithPause "未找到 .env（$EnvFile）。请先复制 .env.example 并填写密钥。"
}
$envText = Get-Content $EnvFile -Raw -ErrorAction SilentlyContinue
if ($envText -notmatch 'OPENAI_API_KEY\s*=\s*\S') {
    Stop-WithPause '.env 中未设置 OPENAI_API_KEY，研搜功能将无法调用大模型。'
}
if ($envText -notmatch 'OPENAI_BASE_URL\s*=\s*\S') {
    Stop-WithPause '.env 中未设置 OPENAI_BASE_URL。'
}
if ($envText -notmatch 'LLM_QWEN_MAX\s*=\s*\S') {
    Stop-WithPause '.env 中未设置 LLM_QWEN_MAX。'
}
Write-Ok '.env 校验通过（LLM 三项配置齐备）'

# --- 1. Docker Desktop ---------------------------------------------------
Write-Step '步骤 1/4 · 确保 Docker 引擎运行'
if (Test-Engine) {
    Write-Ok "引擎已在运行（$((Get-EngineVersion))）"
} else {
    if (-not (Test-Path $DockerDesktop)) {
        Stop-WithPause "未找到 Docker Desktop：$DockerDesktop`n    请手动启动 Docker Desktop 后重跑本脚本。"
    }
    Write-Info '正在启动 Docker Desktop …'
    try {
        Start-Process -FilePath $DockerDesktop -ErrorAction Stop
    } catch {
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $DockerDesktop
            $psi.UseShellExecute = $true
            $null = [System.Diagnostics.Process]::Start($psi)
        } catch {
            Stop-WithPause "启动 Docker Desktop 失败：$($_.Exception.Message)"
        }
    }

    Write-Host '    等待引擎就绪（首次冷启动通常 20-60 秒）' -NoNewline
    $deadline = (Get-Date).AddSeconds(300)
    $engineOk = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        if (Test-Engine) { $engineOk = $true; break }
        Write-Host '.' -NoNewline -ForegroundColor DarkGray
    }
    Write-Host ''
    if ($engineOk) {
        Write-Ok "引擎已就绪（$((Get-EngineVersion))）"
    } else {
        Stop-WithPause '引擎 300 秒内未就绪。请打开 Docker Desktop 手动确认状态后重试。'
    }
}

# --- 2. 启动容器 ----------------------------------------------------------
Write-Step '步骤 2/4 · 启动全部容器（MySQL + 后端 + 前端）'

# 检测本地是否已有应用镜像（backend + frontend）：都有就直接 up -d（秒级拉起），
# 任一缺失才走首次构建（--build 在部分环境下会挂死，只在真正缺镜像时触发）。
$appImages = @('deepsearch-agents-backend:local', 'deepsearch-agents-frontend:local')
$hasAllImages = $true
foreach ($img in $appImages) {
    $id = (& docker images -q $img 2>$null)
    if ([string]::IsNullOrEmpty($id)) { $hasAllImages = $false; break }
}

if (-not $hasAllImages) {
    Write-Info '未找到应用镜像，执行首次构建（约 1-4 分钟）…'
    Write-Host ''
    if (-not (Invoke-Compose -ComposeArgs @('up', '-d', '--build'))) {
        Write-Host ''
        Write-Warn2 'compose up --build 失败，最近日志如下：'
        Write-Host ''
        Invoke-Compose -ComposeArgs @('logs', '--tail', '30') | Out-Null
        Stop-WithPause ''
    }
} else {
    Write-Info '已检测到应用镜像，跳过构建直接启动（如需重建请删除该镜像或运行首次构建脚本）。'
    Write-Host ''
    if (-not (Invoke-Compose -ComposeArgs @('up', '-d'))) {
        Write-Host ''
        Write-Warn2 'compose up 失败，最近日志如下：'
        Write-Host ''
        Invoke-Compose -ComposeArgs @('logs', '--tail', '30') | Out-Null
        Stop-WithPause ''
    }
}
Write-Ok '容器已启动'

# --- 3. 等待后端就绪 ------------------------------------------------------
Write-Step '步骤 3/4 · 等待后端 /health/ready'
Write-Info '就绪判定：LLM_QWEN_MAX / OPENAI_API_KEY / OPENAI_BASE_URL 三项配置齐备'
Write-Host '    ' -NoNewline

$deadline = (Get-Date).AddSeconds(240)
$ready = $false
$dots = 0
while ((Get-Date) -lt $deadline) {
    if (Test-Http200 $ReadyUrl 5000) { $ready = $true; break }
    Start-Sleep -Seconds 4
    Write-Host '.' -NoNewline -ForegroundColor DarkGray
    $dots++
    if ($dots % 15 -eq 0) {
        Write-Host ''
        Write-Host '    ' -NoNewline
    }
}
Write-Host ''

if ($ready) {
    Write-Ok '后端已就绪，LLM 配置校验通过'
} else {
    Write-Warn2 '后端 240 秒内未就绪。'
    Write-Warn2 '诊断命令（在 docker 目录执行）：'
    Write-Host '      docker compose --env-file ..\.env -f docker-compose.yaml -f docker-compose.net.yaml -f docker-compose.app.yaml logs --tail 50 deepsearch-backend' -ForegroundColor DarkGray
    Write-Host '      docker logs deepsearch-backend --tail 50' -ForegroundColor DarkGray
    Write-Host ''
    $ans = Read-Host '是否继续等待并打开界面？(y/N)'
    if ($ans -notmatch '^[Yy]') { exit 1 }
}

# --- 4. 前端 + 浏览器 -----------------------------------------------------
Write-Step '步骤 4/4 · 确认前端并打开浏览器'
# 判定标准用「HTTP 200」而非「端口已监听」：
# 前端是 nginx，若上游服务名启动期解析失败，nginx 会 emerg 退出并陷入
# 重启循环。此时端口可能短暂处于监听态，但页面并不真正可用。
# 用 HTTP 200 才能覆盖这种情况。
$deadline = (Get-Date).AddSeconds(90)
$feOk = $false
while ((Get-Date) -lt $deadline) {
    if (Test-Http200 $FrontendUrl 5000) { $feOk = $true; break }
    Start-Sleep -Seconds 3
}
if ($feOk) {
    Write-Ok '前端已就绪（HTTP 200）'
} else {
    Write-Warn2 '前端未返回 200，界面可能无法访问。最近日志：'
    docker logs --tail 20 deepsearch-frontend 2>&1 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
}

Write-Head '启动完成'
Write-Host "  前端界面：$FrontendUrl"        -ForegroundColor Gray
Write-Host "  接口文档：$DocsUrl"            -ForegroundColor Gray
Write-Host "  健康检查：$ReadyUrl"           -ForegroundColor Gray
Write-Host ''

if ($feOk) {
    Start-Process $FrontendUrl
    Write-Host '  已为你打开浏览器。' -ForegroundColor Green
}

Write-Host ''
Write-Host '  常用命令：' -ForegroundColor DarkGray
Write-Host '    查看状态：     docker ps' -ForegroundColor DarkGray
Write-Host '    查看后端日志： docker logs -f deepsearch-backend' -ForegroundColor DarkGray
Write-Host '    查看 MySQL：   docker logs -f deepsearch-mysql' -ForegroundColor DarkGray
Write-Host '    停止服务：     运行「停止深度研搜.ps1」' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  服务由 Docker 托管，关闭本窗口不会停止服务。' -ForegroundColor DarkGray
Write-Host ''
Read-Host '按回车退出'
