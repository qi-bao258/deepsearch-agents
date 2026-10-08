# =============================================
# deepsearch-agents 一键启动脚本 (Windows PowerShell)
# 启动顺序：MySQL容器 -> 后端(8001) -> 前端(5174)
# 运行方式：powershell -ExecutionPolicy Bypass -File .\start.ps1
# =============================================

# 项目根目录取自脚本自身所在位置，而不是硬编码盘符路径。
# 这样仓库被 clone 到任意目录（或换机器）都能直接运行。
$ProjectRoot = $PSScriptRoot
$ComposeFile = "$ProjectRoot\docker\docker-compose.yaml"
$EnvFile     = "$ProjectRoot\.env"
$BackendPort = 8001

# MySQL root 密码从环境变量读取，未设置时回落到本地开发默认值。
# 不在脚本里写死密码，避免把凭据随仓库提交出去。
$MySqlRootPwd = if ($env:MYSQL_ROOT_PASSWORD) { $env:MYSQL_ROOT_PASSWORD } else { "root" }

Write-Host "==> [1/3] 启动 MySQL 教学库 (Docker)" -ForegroundColor Cyan
docker compose -f $ComposeFile --env-file $EnvFile up -d
if ($LASTEXITCODE -ne 0) {
    Write-Warning "MySQL 启动失败，请确认 Docker Desktop 已打开后重试。"
    exit 1
}

Write-Host "==> 等待 MySQL 就绪..." -ForegroundColor DarkGray
for ($i = 0; $i -lt 30; $i++) {
    docker exec deepsearch-mysql mysqladmin ping -h 127.0.0.1 -uroot "-p$MySqlRootPwd" --silent 2>$null
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep -Seconds 1
}
Write-Host "==> MySQL 已就绪，教学库: deepsearch_db" -ForegroundColor Green

Write-Host "==> [2/3] 启动后端服务 (端口 $BackendPort)" -ForegroundColor Cyan
Start-Process powershell -WorkingDirectory $ProjectRoot -ArgumentList @(
    "-NoExit", "-Command",
    "cd '$ProjectRoot'; uv run uvicorn app.api.server:app --host 0.0.0.0 --port $BackendPort --reload"
)
Write-Host "==> 后端窗口已创建" -ForegroundColor Green

Write-Host "==> [3/3] 启动前端 (Vite)" -ForegroundColor Cyan
Start-Process powershell -WorkingDirectory "$ProjectRoot\frontend" -ArgumentList @(
    "-NoExit", "-Command",
    "cd '$ProjectRoot\frontend'; pnpm dev"
)
Write-Host "==> 前端窗口已创建" -ForegroundColor Green

Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host " 全部启动完成！" -ForegroundColor Green
Write-Host "  后端 API : http://localhost:$BackendPort" -ForegroundColor White
Write-Host "  前端页面: 请查看前端窗口输出的地址 (5173/5174)" -ForegroundColor White
Write-Host "==============================================" -ForegroundColor Green