# =============================================================================
# DeepSearch Agents 后端镜像
#
# 采用两阶段构建：
#   builder  —— 用 uv 解析并安装依赖，装进独立虚拟环境
#   runtime  —— 只拷贝虚拟环境与源码，不含构建工具与 pip 缓存
#
# 这样做的收益：镜像体积显著更小，且运行阶段不携带编译器，
# 减少了一层可被利用的攻击面。
# =============================================================================

# ---------- Stage 1: builder ----------
# 基础镜像版本必须与 pyproject.toml 的 requires-python（>=3.12,<3.13）一致：
# 用了更高版本（如 3.14）会在 `uv sync --frozen` 阶段直接因版本约束失败。
FROM python:3.12-slim AS builder

# uv 由官方镜像直接复制，避免在构建期联网安装 uv 本身
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# 关闭字节码编译可加快安装；把 uv 缓存固定到项目内便于分层缓存命中
ENV UV_COMPILE_BYTECODE=0 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never

WORKDIR /app

# 先只拷贝依赖清单：源码变更时这一层仍能命中缓存，
# 这正是"依赖层与代码层分离"带来的构建加速
COPY pyproject.toml uv.lock ./

# --no-dev 不安装 pytest/ruff 等开发依赖，避免它们进入生产镜像
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project --no-dev

# ---------- Stage 2: runtime ----------
FROM python:3.12-slim AS runtime

# PYTHONDONTWRITEBYTECODE  不在容器内写 .pyc，保持文件系统整洁
# PYTHONUNBUFFERED         日志实时输出，否则容器日志会被缓冲吞掉
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/app/.venv/bin:$PATH" \
    TZ=Asia/Shanghai

WORKDIR /app

# 非 root 用户运行：即使应用被攻破，攻击者也无法直接写系统目录
RUN groupadd --system --gid 1000 appuser \
    && useradd --system --uid 1000 --gid 1000 --create-home appuser

# 从 builder 拷贝已装好的虚拟环境
COPY --from=builder --chown=appuser:appuser /app/.venv /app/.venv

# 拷贝应用源码与运行时资源
COPY --chown=appuser:appuser app ./app
COPY --chown=appuser:appuser pyproject.toml ./

# 运行时目录必须在切到 appuser 之前创建并改属主。
# 关键坑：server.py L68-73 在**模块导入期**就执行 output_dir.mkdir() /
# updated_dir.mkdir()，而 log.py 也会建 logs 目录。若非 root 用户对这些
# 路径没有写权限，容器会在导入阶段直接 CrashLoop（PermissionError），
# 表现为「一启动就退出」，日志里看不到应用自身的报错。
RUN mkdir -p /app/app/output /app/app/updated /app/logs \
    && chown -R appuser:appuser /app

USER appuser

EXPOSE 8001

# 探活打的是就绪接口：它会校验关键环境变量是否齐备。
# 配置漏填时容器会被标记为不健康，而不是等到用户请求失败才发现。
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8001/health/ready', timeout=3).status==200 else 1)"

CMD ["uvicorn", "app.api.server:app", "--host", "0.0.0.0", "--port", "8001"]
