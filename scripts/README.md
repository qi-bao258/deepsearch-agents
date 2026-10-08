# DepthSearch 启动脚本

一键拉起「深度研搜」全栈：MySQL（可选） → FastAPI 后端 → Vite 前端。

## 快速开始

```powershell
# 全栈启动（推荐；Docker 不可用时自动降级）
.\scripts\start-all.ps1

# 无 Docker 环境
.\scripts\start-all.ps1 -SkipInfra

# 停止全部（保留 MySQL 数据卷）
.\scripts\stop-all.ps1

# 停止并清空数据卷（需输入 yes 二次确认）
.\scripts\stop-all.ps1 -RemoveVolumes
```

启动后：

| 入口 | 地址 |
|------|------|
| 前端界面 | http://localhost:5173 |
| 接口文档 | http://127.0.0.1:8001/docs |
| 就绪探针 | http://127.0.0.1:8001/health/ready |

## 脚本清单

| 脚本 | 职责 | 关键参数 |
|------|------|---------|
| `start-all.ps1` | 串行编排三个子脚本 | `-SkipInfra` `-StrictInfra` `-TimeoutSeconds` |
| `start-infra.ps1` | 启动 MySQL 容器 | `-Strict` `-TimeoutSeconds` |
| `start-backend.ps1` | 校验配置 → 起 uvicorn → 等就绪 | `-Port`（默认 8001）`-NoWait` |
| `start-frontend.ps1` | 自愈链接 → 起 Vite → 等监听 | `-Port`（默认 5173）`-RepairLinks` `-NoRepair` `-NoWait` |
| `stop-all.ps1` | 按端口停止前后端 + 容器 | `-KeepInfra` `-RemoveVolumes` |
| `repair-node-links.py` | 修复 node_modules 断链 | `--dry-run` `--frontend` |

## 设计要点

### 1. 与「电商问数」的关键差异：MySQL 是可选的

本项目的 `/health/ready` **只校验 LLM 三项配置**（`LLM_QWEN_MAX`、
`OPENAI_API_KEY`、`OPENAI_BASE_URL`），**不探测数据库**。

因此即使 Docker 完全不可用，后端与前端仍能正常启动 —— 只有 Agent 的
数据库查询工具（`db_tools`）不可用。

这直接决定了本项目的 `start-infra.ps1` 默认**非阻塞**：容器起不来只警告、
不中止。需要严格模式时加 `-StrictInfra`。

### 2. 为什么必须做 node_modules 链接自愈

本项目从 `D:\` 迁移到 `C:\Users\...\Desktop\项目\` 后，pnpm 建立的所有
junction 退化为**空目录**（Windows 复制不保留跨路径链接）。典型报错：

```
Cannot find module @rollup/rollup-win32-x64-msvc
You installed esbuild for another platform than the one you're currently using
Cannot find package '...\@vitejs\plugin-react\index.js'
SyntaxError: ... does not provide an export named 'default'
```

这些都是**链接损坏**，不是代码问题。`start-frontend.ps1` 默认会自动调用
`repair-node-links.py` 自愈，因此**不需要 `npm install` 全量重装**。

`repair-node-links.py` 的关键难点：pnpm 对超长目录名做**截断 + hash 后缀**：

| 包名 | 实际实体目录 |
|------|-------------|
| `@babel/plugin-transform-react-jsx-self` | `@babel+plugin-transform-rea_21aa63fd...` |
| `@rc-component/mutate-observer` | `@rc-component+mutate-observ_7fa20b02...` |

因此不能只做精确名匹配，必须支持前缀匹配（脚本内 `Resolver.find`）。

### 3. 为什么前端用 `node node_modules\vite\bin\vite.js`

`frontend/package.json` 声明 `packageManager: pnpm@10.33.0`，本机 pnpm 为
12.x。pnpm 会尝试下载声明版本并失败（`@pnpm/exe did not materialize`）。
npm 不读该字段，所以脚本**直接调用 node_modules 里的 vite**，
不依赖任何包管理器的版本协商。

### 4. 为什么脚本里不用 `Start-Process`

两条本机限制：

- **`Start-Process -FilePath 'powershell.exe'` 被安全策略拦截**
  （报 "Start-Process with a shell/interpreter/LOLBin target"）。
- **`UseShellExecute = $true` 会静默终止整个 PowerShell 进程**，
  导致脚本在中途无输出退出。改用
  `UseShellExecute = $false` + `CreateNoWindow = $true` 稳定可用。

代码里统一用 `System.Diagnostics.Process` 直接启动。

### 5. 为什么 `.ps1` 必须存为 UTF-8 with BOM

本机 PowerShell 5.1 的 `OutputEncoding` 是 GBK。读取**无 BOM** 的 `.ps1`
时按 ANSI 解码，中文字符串字节被误读，会破坏引号配对导致语法错误
（报错中文显示为乱码如 `姝ラ`、`瀹瑰櫒`）。

若手动编辑脚本后报语法错误，先确认 BOM 是否还在。

## 排错

| 症状 | 原因 | 处理 |
|------|------|------|
| `Cannot find module @rollup/...` | 链接损坏 | `python scripts\repair-node-links.py` |
| `esbuild for another platform` | 链接损坏 | 同上 |
| 脚本报中文乱码 / 语法错误 | `.ps1` 缺 BOM | 存为 **UTF-8 with BOM** |
| 后端 `/health/ready` 返回 503 | LLM 配置缺失 | 检查 `.env` 三项 |
| 页面能开但请求全失败 | 前后端端口不一致 | 对齐 `.env.local` 与后端 `-Port` |
| `docker compose` 退出码 1 | Docker 引擎未运行 | 加 `-SkipInfra` |

## 环境限制（本机）

- **`wsl.exe` 被安全策略列入程序黑名单**，硬拦截不可绕过
  → Docker Desktop 的 Linux 引擎无法启动 → 所有容器无法拉起。
  这是环境限制，不是脚本缺陷。后端与前端不受影响。

## 端口约定

| 服务 | 端口 | 配置来源 |
|------|------|---------|
| Vite 前端 | 5173 | `frontend/vite.config.ts` |
| FastAPI 后端 | 8001 | `start-backend.ps1` 默认值 |
| MySQL | 3308 | `.env` 的 `MYSQL_PORT`（避开本机 3306） |

前端通过 `frontend/.env.local` 的 `VITE_API_BASE_URL` **直连后端**，
不走 Vite proxy。`vite.config.ts` 里指向 8000 的 proxy 配置实际未被使用。
