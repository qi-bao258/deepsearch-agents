<#
    深度研搜 · 停止（容器版）

    双击即可运行。默认只停止容器，保留数据卷（MySQL 数据不丢）。

    用 -RemoveVolumes 可连同数据卷一起删除（慎用，会清空数据库）。
#>

param(
    [switch]$RemoveVolumes
)

$ErrorActionPreference = 'Continue'

$ProjectRoot = $PSScriptRoot
$DockerDir   = Join-Path $ProjectRoot 'docker'
$EnvFile     = Join-Path $ProjectRoot '.env'

$ComposeFiles = @(
    '-f', 'docker-compose.yaml',
    '-f', 'docker-compose.net.yaml',
    '-f', 'docker-compose.app.yaml'
)

function Write-Head([string]$t) {
    Write-Host ''
    Write-Host '=============================================' -ForegroundColor White
    Write-Host "  $t" -ForegroundColor White
    Write-Host '=============================================' -ForegroundColor White
}
function Write-Ok([string]$t)   { Write-Host "    [OK]   $t" -ForegroundColor Green }
function Write-Warn2([string]$t){ Write-Host "    [WARN] $t" -ForegroundColor Yellow }
function Write-Info([string]$t) { Write-Host "    $t" -ForegroundColor Gray }

function Invoke-Compose {
    # 参数名不能用 $Args —— 它是 PowerShell 自动变量，会遮蔽同名自定义参数，
    # 导致传进来的数组变空（实测 all=compose，stop 子命令丢失，容器根本没停）。
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

Write-Head '深度研搜 · 停止服务'

if (-not (Test-Path $DockerDir)) {
    Write-Warn2 "未找到 docker 目录：$DockerDir"
    Read-Host '按回车退出'
    exit 1
}

# 引擎没跑就无所谓停止
$engineOk = $false
try {
    $null = & docker info --format '{{.ServerVersion}}' 2>&1
    $engineOk = ($LASTEXITCODE -eq 0)
} catch { $engineOk = $false }

if (-not $engineOk) {
    Write-Info 'Docker 引擎未运行，服务本就不在运行状态。'
    Write-Host ''
    Read-Host '按回车退出'
    exit 0
}

if ($RemoveVolumes) {
    Write-Host ''
    Write-Warn2 '⚠ 即将停止服务并删除数据卷（MySQL 数据将永久丢失）'
    $ans = Read-Host '确认继续？输入 YES 以执行'
    if ($ans -cne 'YES') {
        Write-Info '已取消。'
        Read-Host '按回车退出'
        exit 0
    }
    if (Invoke-Compose -ComposeArgs @('down', '-v')) {
        Write-Ok '容器与数据卷已删除'
    } else {
        Write-Warn2 '删除命令返回非零，请检查下方状态。'
    }
} else {
    if (Invoke-Compose -ComposeArgs @('stop')) {
        Write-Ok '停止命令已执行'
    } else {
        Write-Warn2 '停止命令返回非零，请检查下方状态。'
    }
}

# --- 复验：不只信命令退出码，再实际查一次容器状态 -------------------------
# 这一步是必需的：命令可能"返回 0 但实际没停"，或参数拼错导致空转。
Write-Host ''
Write-Info '复验容器状态…'
$running = @()
try {
    $running = @(& docker ps --filter 'name=deepsearch' --format '{{.Names}}' 2>$null |
                 Where-Object { $_ -and $_.Trim() -ne '' })
} catch { }

if ($running.Count -eq 0) {
    Write-Ok '已确认：深度研搜容器均已停止'
} else {
    Write-Warn2 "仍有容器在运行：$($running -join ', ')"
    Write-Info  '可尝试：docker stop ' + ($running -join ' ')
}

Write-Host ''
Write-Info '重新启动：运行「启动深度研搜.ps1」'
Write-Host ''
Read-Host '按回车退出'
