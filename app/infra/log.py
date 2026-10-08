"""
统一日志基础设施

替换项目里散落的 print：
- print 没有级别、没有时间戳、没有来源定位，服务化之后无法用于排障
- print 无法按级别过滤，也无法落盘轮转，容器里只能靠日志平台抓 stdout

这里提供 loguru 的集中配置，并复用 app/api/context.py 中已有的
session_id / thread_id ContextVar，让每条日志自动带上会话标识——
一个会话的上百条日志因此可以被一条命令串起来看。
"""

import sys
from pathlib import Path

from loguru import logger

from app.api.context import get_session_context, get_thread_context

# 日志格式：时间 | 级别 | 会话标识 | 调用位置 | 消息
# 会话标识放在靠前位置，便于肉眼扫读时快速确认日志属于哪次任务
_LOG_FORMAT = (
    "<green>{time:YYYY-MM-DD HH:mm:ss.SSS}</green> | "
    "<level>{level: <8}</level> | "
    "<magenta>session={extra[session]}</magenta> | "
    "<cyan>{name}</cyan>:<cyan>{function}</cyan>:<cyan>{line}</cyan> - "
    "<level>{message}</level>"
)

# 日志目录固定在项目根下，与 output / updated 同级，便于统一清理与挂载
_LOG_DIR = Path(__file__).parents[2] / "logs"


def _inject_context(record) -> None:
    """把协程上下文中的 session_id / thread_id 注入每条日志"""
    record["extra"]["session"] = get_session_context() or "-"
    record["extra"]["thread"] = get_thread_context() or "-"


def setup_logger(level: str = "INFO") -> None:
    """
    初始化日志输出目标。

    幂等：先 remove 再 add，避免模块被多次导入时重复挂 handler 导致日志翻倍。
    控制台输出面向容器标准输出采集，文件输出面向本地排查与轮转留存。
    """
    logger.remove()
    logger.configure(patcher=_inject_context)

    # 容器与本地开发都以 stdout 为主通道
    logger.add(
        sink=sys.stdout,
        level=level,
        format=_LOG_FORMAT,
        colorize=True,
        backtrace=False,
        diagnose=False,  # 关闭变量值回显，避免把 API Key 等敏感值打进日志
    )

    # 文件通道：按天轮转、保留 7 天，编码固定 utf-8 以免中文在 Windows 下乱码
    try:
        _LOG_DIR.mkdir(parents=True, exist_ok=True)
        logger.add(
            sink=_LOG_DIR / "app.log",
            level=level,
            format=_LOG_FORMAT,
            rotation="00:00",  # 每天零点切分
            retention="7 days",
            encoding="utf-8",
            enqueue=True,  # 多协程并发写入时串行化，避免日志行交错
            backtrace=False,
            diagnose=False,
        )
    except OSError:
        # 目录不可写（如只读容器）时降级为仅控制台输出，不让日志配置拖垮启动
        logger.warning(f"日志目录不可写，已降级为仅控制台输出: {_LOG_DIR}")


# 模块导入即完成配置，业务代码 `from app.infra.log import logger` 即可使用
setup_logger()

__all__ = ["logger", "setup_logger"]
