"""
FastAPI 接口层与项目闭环入口

负责承接前端的任务提交、任务取消、文件上传/下载、输出文件列表查询和
WebSocket 长连接。HTTP 接口只做轻量调度，真正的 DeepAgents 执行放到后台
任务中；执行进度、工具调用和最终结果由 monitor 按 thread_id 推送给前端。

除业务接口外，这里还承担两项横切职责：
1. 统一异常出口：把异常收敛成带业务错误码的 JSON，避免默认格式泄漏堆栈
2. 双探针健康检查：/health 判存活，/health/ready 判就绪
"""

import asyncio
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from typing import List

import uvicorn
from fastapi import (
    FastAPI,
    File,
    Form,
    HTTPException,
    Request,
    UploadFile,
    WebSocket,
    WebSocketDisconnect,
)
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, Field

from app.agent.main_agent import run_deep_agent
from app.api.exception import AppError, ErrorCode
from app.api.monitor import manager
from app.infra.log import logger

# 允许上传的单个文件大小上限（50 MB）。
# 没有上限时，一个超大文件就能打满磁盘或拖垮请求处理。
MAX_UPLOAD_SIZE = 50 * 1024 * 1024


@asynccontextmanager
async def lifespan(_app: FastAPI):
    """
    服务生命周期入口。

    启动时绑定当前事件循环到 WebSocket 管理器，确保后台 Agent 任务可以把
    monitor 事件投递回 FastAPI 所在的 loop。
    """
    loop = asyncio.get_running_loop()
    manager.set_loop(loop)
    logger.info(f"WebSocket Manager 已绑定事件循环 loop_id={id(loop)}")
    yield


# 当前文件位于 app/api/server.py，运行时目录统一收敛到 app 目录
current_dir = Path(__file__).resolve().parent
project_root = current_dir.parent

app = FastAPI(title="DeepAgents API", lifespan=lifespan)

# 保存 thread_id -> 后台 Agent 任务，用于同一会话任务替换和主动取消
active_tasks: dict[str, asyncio.Task] = {}

# output 保存每个会话最终工作区，前端只允许从这里浏览和下载生成文件
output_dir = project_root / "output"
output_dir.mkdir(exist_ok=True)

# updated 暂存用户上传文件，run_deep_agent 启动时会复制到对应 output/session_xxx
updated_dir = project_root / "updated"
updated_dir.mkdir(exist_ok=True)

# CORS 配置。
# 原实现是 allow_origins=["*"] 搭配 allow_credentials=True —— 这是一个危险的组合：
# 带凭证的跨域请求若放开任意源，等于允许任意站点以用户身份调用本服务。
# 这里收敛为前端本地开发地址，生产环境再替换为实际域名。
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        # 容器模式：前端由 Nginx 托管，映射到宿主 5174
        # （固定 5174 以避开同机电商问数项目占用的 5173）
        "http://localhost:5174",
        "http://127.0.0.1:5174",
        # 开发模式：vite dev server 默认 5173（见 frontend/vite.config.ts）
        "http://localhost:5173",
        "http://127.0.0.1:5173",
    ],
    allow_credentials=True,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)


class TaskRequest(BaseModel):
    """前端启动任务时提交的请求体。"""

    query: str = Field(min_length=1, description="用户提交的任务描述")
    # 原实现写作 `thread_id: str = None`：声明为非 Optional 却默认 None，
    # 是典型的类型与运行时不符，改用 Optional 让校验与语义一致。
    thread_id: str | None = None


def _forget_task(thread_id: str, task: asyncio.Task) -> None:
    """
    清理已结束任务的登记关系。

    done_callback 触发时，active_tasks 中可能已经被新任务替换；只有仍是同一个
    task 时才删除，避免误清理同 thread_id 下刚启动的新任务。
    """
    if active_tasks.get(thread_id) is task:
        active_tasks.pop(thread_id, None)


@app.exception_handler(AppError)
async def handle_app_error(request: Request, exc: AppError) -> JSONResponse:
    """业务异常统一出口：稳定的 message + 分段错误码"""
    logger.warning(f"业务异常 code={int(exc.code)} message={exc.message}")
    return JSONResponse(status_code=exc.http_status, content=exc.to_dict())


@app.exception_handler(Exception)
async def handle_unknown_error(request: Request, exc: Exception) -> JSONResponse:
    """兜底异常处理器：避免默认格式把堆栈信息带回客户端"""
    logger.exception(f"未处理异常: {exc!r}")
    return JSONResponse(
        status_code=500,
        content={
            "code": int(ErrorCode.INTERNAL_ERROR),
            "message": "服务内部错误",
            "detail": None,
        },
    )


@app.get("/health", tags=["ops"])
async def health():
    """
    存活探针。

    只反映进程是否存活，不探测下游依赖——依赖探活由 /health/ready 承担，
    避免把外部服务抖动误判成本服务不可用而导致被反复重启。
    """
    return {"status": "ok"}


@app.get("/health/ready", tags=["ops"])
async def readiness():
    """
    就绪探针。

    本项目的关键外部依赖是 LLM 与向量检索服务，它们都通过环境变量配置；
    这里校验配置是否齐备（而非发真实请求），既能拦住"配置漏填导致必然失败"
    这类最常见的部署问题，又不会让探针本身变成外部服务的压力来源。
    """
    import os

    required = ["LLM_QWEN_MAX", "OPENAI_API_KEY", "OPENAI_BASE_URL"]
    checks = {key: bool(os.getenv(key)) for key in required}
    ready = all(checks.values())

    if not ready:
        logger.warning(
            f"就绪检查未通过，缺失配置: {[k for k, v in checks.items() if not v]}"
        )

    return JSONResponse(
        status_code=200 if ready else 503,
        content={
            "status": "ready" if ready else "not_ready",
            "dependencies": checks,
        },
    )


@app.post("/api/task")
async def run_task(request: TaskRequest):
    """
    启动一次 DeepAgents 后台任务。

    HTTP 请求只负责创建后台协程并立即返回，后续执行轨迹、子智能体调用和最终
    答案都会由 monitor 通过 `/ws/{thread_id}` 推送给同一会话的前端。
    """
    thread_id = request.thread_id or str(uuid.uuid4())

    # 同一个 thread_id 只保留一个活跃任务，新任务会先取消旧任务，避免并发写同一会话目录
    old_task = active_tasks.get(thread_id)
    if old_task and not old_task.done():
        logger.info(f"替换同会话旧任务 thread_id={thread_id}")
        old_task.cancel()

    # create_task 把长耗时 Agent 执行交给事件循环，接口本身不用等待最终结果
    task = asyncio.create_task(run_deep_agent(request.query, thread_id))
    active_tasks[thread_id] = task
    task.add_done_callback(lambda finished_task: _forget_task(thread_id, finished_task))

    logger.info(f"任务已启动 thread_id={thread_id}")
    return {"status": "started", "thread_id": thread_id}


@app.post("/api/task/{thread_id}/cancel")
async def cancel_task(thread_id: str):
    """
    取消指定 thread_id 对应的后台 Agent 任务。

    注意：取消会向 asyncio.Task 注入 CancelledError。若底层第三方工具正在执行不可中断
    的同步阻塞调用，任务可能需要等该调用返回后才会真正结束。
    """
    task = active_tasks.get(thread_id)
    if not task or task.done():
        active_tasks.pop(thread_id, None)
        raise HTTPException(status_code=404, detail="任务不存在或已结束")

    # 先发出取消信号，再短暂等待协程响应；
    # 若底层阻塞中，则返回 cancelling 给前端继续展示状态
    task.cancel()
    try:
        await asyncio.wait_for(task, timeout=1.0)
    except asyncio.CancelledError:
        _forget_task(thread_id, task)
        return {"status": "cancelled", "thread_id": thread_id}
    except asyncio.TimeoutError:
        return {"status": "cancelling", "thread_id": thread_id}
    except Exception as e:
        _forget_task(thread_id, task)
        return {"status": "cancelled", "thread_id": thread_id, "message": str(e)}

    _forget_task(thread_id, task)
    return {"status": "cancelled", "thread_id": thread_id}


@app.post("/api/upload")
async def upload_files(files: List[UploadFile] = File(...), thread_id: str = Form(...)):
    """
    文件上传接口 (File Upload)。

    目标：
    1. 接收用户上传的一个或多个文件。
    2. 保存到 `updated/session_{thread_id}` 目录。
    3. 供 Agent 在后续任务中读取和分析。

    Args:
        files (List[UploadFile]): 文件对象列表。
        thread_id (str): 关联的任务会话 ID。
    """
    # thread_id 参与目录拼接，必须先校验，避免 `../` 逃出 updated 目录
    if not thread_id or "/" in thread_id or "\\" in thread_id or ".." in thread_id:
        raise AppError("thread_id 含非法字符", code=ErrorCode.INVALID_PARAM)

    # 上传文件先按会话隔离保存，避免不同任务读取到彼此的附件
    target_dir = updated_dir / f"session_{thread_id}"
    target_dir.mkdir(parents=True, exist_ok=True)

    saved_files = []
    for file in files:
        # 关键修复：原实现是 target_dir / file.filename，而 filename 完全由客户端提供。
        # 客户端传 "../../app/config.py" 就能覆盖项目源码（路径穿越写）。
        # Path(...).name 只取最后一段，剥离掉任何目录成分。
        safe_name = Path(file.filename or "").name
        if not safe_name or safe_name in {".", ".."}:
            logger.warning(f"跳过非法文件名: {file.filename!r}")
            continue

        file_path = target_dir / safe_name

        # 二次确认最终路径仍在目标目录内，防止平台差异导致的意外
        if not file_path.resolve().is_relative_to(target_dir.resolve()):
            logger.warning(f"拒绝越界的上传路径: {file_path}")
            continue

        # 分块写入并累计大小，超限立即中断，避免大文件占满磁盘
        size = 0
        try:
            with file_path.open("wb") as buffer:
                while chunk := await file.read(1024 * 1024):
                    size += len(chunk)
                    if size > MAX_UPLOAD_SIZE:
                        buffer.close()
                        file_path.unlink(missing_ok=True)
                        limit_mb = MAX_UPLOAD_SIZE // 1024 // 1024
                        raise AppError(
                            f"文件 {safe_name} 超过 {limit_mb} MB 上限",
                            code=ErrorCode.FILE_ERROR,
                        )
                    buffer.write(chunk)
        except AppError:
            raise
        except Exception as e:
            logger.exception(f"上传文件写入失败: {safe_name}")
            raise AppError(f"文件写入失败: {e}", code=ErrorCode.FILE_ERROR) from e

        saved_files.append(safe_name)
        logger.info(f"上传完成 name={safe_name} size={size}")

    return {"status": "uploaded", "files": saved_files}


@app.get("/api/download")
async def download_file(path: str):
    """
    文件下载接口 (File Download)。

    目标：
    1. 根据绝对路径下载文件。
    2. 严格的安全检查，防止越权访问。

    Args:
        path (str): 文件的绝对路径 (通常从 list_files 接口获取)。
    """
    try:
        # resolve 后再做 is_relative_to，防止 `../` 之类的路径穿越到 output 之外
        abs_path = Path(path).resolve()
        output_abs = output_dir.resolve()

        if not abs_path.is_relative_to(output_abs):
            logger.warning(f"下载请求越界被拒: {abs_path}")
            return {"error": "拒绝访问: 只能下载输出目录下的文件"}
    except Exception as e:
        logger.warning(f"下载路径解析失败: {e}")
        return {"error": "无效的路径参数"}

    if not abs_path.exists():
        return {"error": "文件不存在"}

    # FileResponse 会以流式响应返回文件内容，并让浏览器使用原文件名下载
    return FileResponse(abs_path, filename=abs_path.name)


@app.get("/api/files")
async def list_files(path: str):
    """
    文件列表查询接口 (File Explorer)。

    目标：
    1. 列出指定目录下的所有生成文件。
    2. 提供文件元数据（大小、修改时间、下载所需路径）。
    3. 严格的安全检查，防止路径遍历攻击。

    Args:
        path (str): 目标目录的绝对路径 (必须在 output 目录下)。
    """
    logger.debug(f"请求文件列表 path={path}")

    try:
        # 和下载接口保持同一条安全边界：前端只能查看 output 目录内部内容
        abs_path = Path(path).resolve()
        output_abs = output_dir.resolve()

        if not abs_path.is_relative_to(output_abs):
            logger.warning(f"文件列表请求越界被拒: {abs_path}")
            return {"error": "拒绝访问: 只能访问输出目录下的文件"}

    except Exception as e:
        logger.warning(f"文件列表路径解析失败: {e}")
        return {"error": f"路径无效: {e}"}

    if not abs_path.exists():
        return {"error": "目录不存在"}

    files = []
    try:
        # 递归返回文件元数据，前端据此渲染文件列表并发起下载请求
        for file_path in abs_path.rglob("*"):
            if file_path.is_file():
                stat = file_path.stat()
                files.append(
                    {
                        "name": file_path.name,
                        "type": "file",
                        "path": str(file_path),
                        "size": stat.st_size,
                        "mtime": stat.st_mtime,
                    }
                )

    except Exception as e:
        logger.exception(f"遍历文件失败: {e}")
        return {"error": str(e)}

    # 最新生成的文件排在前面，方便用户优先看到本次任务产物
    files.sort(key=lambda x: x.get("mtime", 0), reverse=True)
    logger.debug(f"文件列表返回 count={len(files)}")
    return {"files": files}


@app.websocket("/ws/{thread_id}")
async def websocket_endpoint(websocket: WebSocket, thread_id: str):
    """
    WebSocket 实时通讯核心接口 (Real-time Communication)。

    连接建立后，ConnectionManager 会用 thread_id 保存 WebSocket。monitor 后续
    发送事件时只需要按 thread_id 查找连接，就能把进度推给对应页面。循环中的
    receive_text 用于接收前端心跳，避免连接空闲断开。

    鉴权说明：当前未校验身份，任何知道 thread_id 的客户端都能订阅该会话的事件。
    对于本地教学场景可接受；对外部署时应在 connect 前校验 token——
    否则 thread_id 一旦泄漏，任务过程与结果都会暴露给第三方。
    """
    logger.info(f"WebSocket 连接请求 thread_id={thread_id}")

    # 连接建立后立即按 thread_id 注册，monitor 后续才能把事件定向推给当前页面
    await manager.connect(websocket, thread_id)

    try:
        while True:
            # 前端通常发送 ping 心跳；服务端回复 pong，顺便维持连接活跃
            data = await websocket.receive_text()
            await websocket.send_json(
                {"type": "pong", "message": f"服务端已收到: {data}"}
            )

    except WebSocketDisconnect:
        # 只移除当前 WebSocket 实例，避免旧连接断开时误删同 thread_id 的新连接
        manager.disconnect(websocket, thread_id)
        logger.info(f"WebSocket 客户端已断开 thread_id={thread_id}")

    except Exception as e:
        logger.exception(f"WebSocket 连接异常 thread_id={thread_id}: {e}")
        manager.disconnect(websocket, thread_id)


if __name__ == "__main__":
    uvicorn.run("api.server:app", host="0.0.0.0", port=8000, reload=True)
