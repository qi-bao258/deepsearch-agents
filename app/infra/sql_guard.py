"""
SQL 安全护栏

大模型生成的 SQL 与其参数本质上不可信。本模块在 SQL 抵达数据库之前提供
一组确定性规则作为程序化防线——Prompt 约束是"建议"，程序化校验才是"边界"。

提供两级校验：
1. guard_sql(sql)          —— 校验整条语句：只放行 SELECT/WITH，
                              拒绝多语句与写操作，强制 LIMIT
2. guard_identifier(name)  —— 校验表名/字段名：只允许字母数字下划线

第二级不可省略：`SELECT * FROM {table_name}` 这类语句无法靠整句校验兜住，
因为表名本身就是拼接进 SQL 的自由文本。
"""

import re
from dataclasses import dataclass
from typing import Final

# 只放行查询语句
_ALLOWED_PREFIXES: Final[tuple[str, ...]] = ("select", "with")

# 命中任意一项即拒绝
_FORBIDDEN_KEYWORDS: Final[tuple[str, ...]] = (
    "insert",
    "update",
    "delete",
    "drop",
    "truncate",
    "alter",
    "create",
    "replace",
    "grant",
    "revoke",
    "rename",
    "load_file",
    "outfile",
    "dumpfile",
    "into outfile",
    "for update",
    "lock in share mode",
)

# 合法标识符：字母或下划线开头，后接字母数字下划线，最长 64 字符
_IDENTIFIER_PATTERN: Final[re.Pattern[str]] = re.compile(
    r"^[A-Za-z_][A-Za-z0-9_]{0,63}$"
)

_DEFAULT_MAX_ROWS: Final[int] = 1000
_DEFAULT_MAX_LENGTH: Final[int] = 20_000


class SQLGuardError(ValueError):
    """SQL 未通过安全校验时抛出"""


@dataclass(frozen=True)
class GuardedSQL:
    """护栏处理结果"""

    sql: str
    limit_injected: bool


def _normalize(sql: str) -> str:
    """去掉首尾空白与结尾分号"""
    return sql.strip().rstrip(";").strip()


def _strip_string_literals(sql: str) -> str:
    """
    把字符串字面量折叠成占位符再做关键字扫描。

    否则 `WHERE name = 'delete'` 这种合法查询会因值含 delete 被误杀，
    而 `; DROP TABLE x` 这类真实注入仍能被识别。
    """
    return re.sub(r"'[^']*'|\"[^\"]*\"", "''", sql)


def guard_identifier(name: str, *, kind: str = "标识符") -> str:
    """
    校验表名 / 字段名，拒绝任何可能改变语句结构的字符。

    :param name: 待校验的标识符
    :param kind: 错误信息中的名称，便于定位是表名还是字段名
    :return: 通过校验的标识符
    :raises SQLGuardError: 为空或含非法字符
    """
    if not name or not isinstance(name, str):
        raise SQLGuardError(f"{kind}为空")

    candidate = name.strip()
    if not _IDENTIFIER_PATTERN.match(candidate):
        raise SQLGuardError(f"{kind}含非法字符：{name!r}（仅允许字母、数字、下划线）")

    return candidate


def guard_sql(
    sql: str,
    max_rows: int = _DEFAULT_MAX_ROWS,
    max_length: int = _DEFAULT_MAX_LENGTH,
) -> GuardedSQL:
    """
    对 SQL 做安全校验与行数约束。

    :param sql: 待校验的 SQL 文本
    :param max_rows: 允许返回的最大行数，超过则收紧
    :param max_length: 允许的最大语句长度（字符）
    :return: 处理后的 GuardedSQL
    :raises SQLGuardError: 语句类型非法、含禁止关键字、多语句或超长
    """
    if not sql or not sql.strip():
        raise SQLGuardError("SQL 语句为空")

    normalized = _normalize(sql)
    scanned = _strip_string_literals(normalized)

    if len(scanned) > max_length:
        raise SQLGuardError(f"SQL 语句过长（{len(scanned)} 字符，上限 {max_length}）")

    if ";" in scanned:
        raise SQLGuardError("检测到多语句拼接，已拒绝执行")

    lowered = scanned.lower().strip()
    if not any(lowered.startswith(p) for p in _ALLOWED_PREFIXES):
        first_word = normalized.split()[0] if normalized.split() else "空语句"
        raise SQLGuardError(f"仅允许执行查询语句，当前语句以 `{first_word}` 开头")

    for keyword in _FORBIDDEN_KEYWORDS:
        # 词边界匹配，避免 update_time 这类字段名被误判
        if re.search(rf"\b{re.escape(keyword)}\b", lowered):
            raise SQLGuardError(f"SQL 中包含被禁止的关键字：{keyword}")

    # LIMIT 处理：无则补齐，超界则收紧
    existing = re.search(r"\blimit\s+(\d+)\s*$", normalized, flags=re.IGNORECASE)
    if existing is None:
        return GuardedSQL(sql=f"{normalized} LIMIT {max_rows}", limit_injected=True)

    if int(existing.group(1)) <= max_rows:
        return GuardedSQL(sql=normalized, limit_injected=False)

    clamped = re.sub(
        r"\blimit\s+\d+\s*$", f"LIMIT {max_rows}", normalized, flags=re.IGNORECASE
    )
    return GuardedSQL(sql=clamped, limit_injected=True)
