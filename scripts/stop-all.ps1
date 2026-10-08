<#
.SYNOPSIS
    停止「DepthSearch」全栈服务。

.DESCRIPTION
    按与启动相反的顺序停止：前端 → 后端 → MySQL 容器。

    默认**保留数据卷**，下次 start-infra 可直接恢复，不需要重新导入
    docker/mysql/mysql.sql。

.PARAMETER KeepInfra
    只停前端与后端，保留 MySQL 容器运行。

.PARAMETER RemoveVolumes
    危险操作：连数据卷一并删除。执行前需输入 yes 二次确认。
    删除后容器重建时会重新执行 docker/mysql/mysql.sql 初始化脚本。

.EXAMPLE
    .\scripts\stop-all.ps1
    停止全部服务。

.EXAMPLE
    .\scripts\stop-all.ps1 -KeepInfra
    只停应用层，MySQL 继续运行。
#>

[CmdletBinding()]
param(
    [switch]$KeepInfra,
    [switch]$RemoveVolumes
)

$ErrorActionPreference = 'Continue'
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

function Stop-PortProcess {
    <#
      按监听端口定位并结束进程。
      额外校验进程名，避免误杀恰好占用同端口的其它程序。
    #>
    param(
        [int]$Port,
        [string]$ExpectedName
    )

    $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if (-not $conns) {
        Write-Host "    端口 $Port 未监听，跳过" -ForegroundColor DarkGray
        return
    }

    $killed = @()
    foreach ($c in $conns) {
        $targetPid = $c.OwningProcess
        $proc = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
        if (-not $proc) { continue }

        $name = $proc.ProcessName
        if ($ExpectedName -and ($name -notmatch $ExpectedName)) {
            Write-Host "    端口 $Port 由 $name (PID $targetPid) 占用，与预期（$ExpectedName）不符，跳过" -ForegroundColor Yellow
            continue
        }

        try {
            Stop-Process -Id $targetPid -Force -ErrorAction Stop
            $killed += "$name (PID $targetPid)"
        } catch {
            Write-Host "    结束 $name (PID $targetPid) 失败：$($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if ($killed.Count -gt 0) {
        Write-Ok "已停止：$($killed -join ', ')"
    }
}

# --- 前端 -----------------------------------------------------------------
Write-Step "步骤 1/3 · 停止前端 (5173)"
Stop-PortProcess -Port 5173 -ExpectedName 'node'

# --- 后端 -----------------------------------------------------------------
Write-Step "步骤 2/3 · 停止后端 (8001)"
Stop-PortProcess -Port 8001 -ExpectedName '.+'

# --- 容器 -----------------------------------------------------------------
if ($KeepInfra) {
    Write-Step "步骤 3/3 · MySQL：已跳过（-KeepInfra）"
} else {
    $composeArgs = @('compose', '-f', $ComposeFile)
    if (Test-Path $EnvFile) { $composeArgs += @('--env-file', $EnvFile) }

    if ($RemoveVolumes) {
        Write-Step "步骤 3/3 · 停止容器并删除数据卷"
        Write-Host ""
        Write-Host "    ⚠️  警告：此操作会删除 MySQL 数据卷。" -ForegroundColor Red
        Write-Host "       容器重建时将重新执行 docker/mysql/mysql.sql 初始化脚本。" -ForegroundColor Red
        Write-Host ""
        $answer = Read-Host "    确认删除数据卷？输入 yes 继续"
        if ($answer -eq 'yes') {
            & docker @composeArgs down -v
        } else {
            Write-Host "    已取消，改为仅停止容器（保留数据卷）" -ForegroundColor Yellow
            & docker @composeArgs stop
        }
    } else {
        Write-Step "步骤 3/3 · 停止容器（保留数据卷）"
        & docker @composeArgs stop
    }

    if ($LASTEXITCODE -eq 0) {
        Write-Ok "容器已停止，数据卷保留"
    } else {
        Write-Host "    docker compose 返回退出码 $LASTEXITCODE（Docker 未运行时属正常）" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "停止完成。" -ForegroundColor Green
Write-Host ""
