"""
统一错误码与业务异常

与 deepsearch 的分层对应：
    10000 段 —— 通用 / 参数
    20000 段 —— LLM 与 Agent 执行
    30000 段 —— 工具与检索
    40000 段 —— 数据库与 SQL
    50000 段 —— 文件与存储
"""

from enum import IntEnum
from typing import Any


class ErrorCode(IntEnum):
    """业务错误码，分段便于前端与告警分流"""

    # 10000 段：通用
    UNKNOWN = 10000
    INVALID_PARAM = 10001
    INTERNAL_ERROR = 10002

    # 20000 段：Agent / LLM
    AGENT_ERROR = 20001
    LLM_ERROR = 20002

    # 30000 段：工具与检索
    TOOL_ERROR = 30001
    RETRIEVAL_ERROR = 30002

    # 40000 段：数据库
    SQL_GUARD_REJECTED = 40001
    DB_ERROR = 40002

    # 50000 段：文件
    FILE_ERROR = 50001
    FILE_SECURITY_REJECTED = 50002


_DEFAULT_MESSAGES: dict[ErrorCode, str] = {
    ErrorCode.UNKNOWN: "服务开小差了，请稍后重试",
    ErrorCode.INVALID_PARAM: "请求参数不合法",
    ErrorCode.INTERNAL_ERROR: "服务内部错误",
    ErrorCode.AGENT_ERROR: "任务执行失败，请稍后重试",
    ErrorCode.LLM_ERROR: "模型服务暂时不可用",
    ErrorCode.TOOL_ERROR: "工具调用失败",
    ErrorCode.RETRIEVAL_ERROR: "检索服务暂时不可用",
    ErrorCode.SQL_GUARD_REJECTED: "查询被安全策略拦截",
    ErrorCode.DB_ERROR: "数据库查询失败",
    ErrorCode.FILE_ERROR: "文件操作失败",
    ErrorCode.FILE_SECURITY_REJECTED: "文件路径超出允许范围",
}


# 错误码 -> HTTP 状态码的默认映射。
# 让 code 与 status 联动，而不是各写各的：调用方只需给一个精确的 code，
# 状态码自动跟随，避免出现"code 是参数错误、状态码却是 500"这类不一致。
_CODE_TO_STATUS: dict[ErrorCode, int] = {
    ErrorCode.UNKNOWN: 500,
    ErrorCode.INVALID_PARAM: 400,
    ErrorCode.INTERNAL_ERROR: 500,
    ErrorCode.AGENT_ERROR: 500,
    ErrorCode.LLM_ERROR: 503,
    ErrorCode.TOOL_ERROR: 500,
    ErrorCode.RETRIEVAL_ERROR: 503,
    ErrorCode.SQL_GUARD_REJECTED: 400,
    ErrorCode.DB_ERROR: 500,
    ErrorCode.FILE_ERROR: 500,
    ErrorCode.FILE_SECURITY_REJECTED: 400,
}


class AppError(Exception):
    """业务异常基类，由全局异常处理器统一转换成 JSON 响应"""

    http_status: int = 500
    code: ErrorCode = ErrorCode.UNKNOWN

    def __init__(
        self,
        message: str | None = None,
        *,
        code: ErrorCode | None = None,
        detail: Any = None,
    ):
        self.code = code or self.code
        self.message = message or _DEFAULT_MESSAGES.get(self.code, "服务异常")
        # detail 只进日志与响应体（便于排障），但 message 保持稳定可读
        self.detail = detail
        # 若调用方显式传了 code，状态码跟随该 code 的语义；
        # 否则沿用子类声明的 http_status（子类覆盖优先）。
        if code is not None:
            self.http_status = _CODE_TO_STATUS.get(code, self.http_status)
        super().__init__(self.message)

    def to_dict(self) -> dict:
        """转换为统一响应信封"""
        return {
            "code": int(self.code),
            "message": self.message,
            "detail": self.detail,
        }


class ParamError(AppError):
    """入参校验失败"""

    http_status = 400
    code = ErrorCode.INVALID_PARAM


class FileSecurityError(AppError):
    """文件路径越界"""

    http_status = 400
    code = ErrorCode.FILE_SECURITY_REJECTED


class AgentError(AppError):
    """Agent 执行失败"""

    http_status = 500
    code = ErrorCode.AGENT_ERROR


class SQLGuardRejected(AppError):
    """SQL 未通过护栏"""

    http_status = 400
    code = ErrorCode.SQL_GUARD_REJECTED
