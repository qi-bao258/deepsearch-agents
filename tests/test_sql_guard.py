"""
SQL 安全护栏单元测试

覆盖两级校验：
1. guard_sql        —— 整句校验：白名单语句类型、拦截写操作与多语句、强制 LIMIT
2. guard_identifier —— 标识符校验：表名/字段名只允许字母数字下划线

这些测试是纯函数级的，不依赖数据库连接，可在 CI 中快速执行。
"""

import pytest

from app.infra.sql_guard import GuardedSQL, SQLGuardError, guard_identifier, guard_sql


class TestStatementWhitelist:
    """语句类型白名单"""

    @pytest.mark.parametrize(
        "sql",
        [
            "SELECT 1",
            "SELECT * FROM orders WHERE dt = '2026-01-01'",
            "WITH t AS (SELECT 1 AS a) SELECT a FROM t",
            "  select count(*) from dim_region  ",
        ],
    )
    def test_allows_select_and_cte(self, sql):
        """SELECT 与 WITH 开头的查询应放行"""
        result = guard_sql(sql)
        assert result.sql.upper().startswith(("SELECT", "WITH"))

    @pytest.mark.parametrize(
        "sql",
        [
            "DELETE FROM orders",
            "DROP TABLE orders",
            "UPDATE orders SET amount = 0",
            "INSERT INTO orders VALUES (1)",
            "TRUNCATE TABLE orders",
            "CREATE TABLE t (a int)",
            "ALTER TABLE orders ADD COLUMN b int",
            "GRANT ALL ON dw.* TO 'x'@'%'",
        ],
    )
    def test_rejects_non_select(self, sql):
        """任何非查询语句都必须拒绝"""
        with pytest.raises(SQLGuardError):
            guard_sql(sql)

    def test_rejects_stacked_statements(self):
        """分号拼接的多语句必须拦截"""
        with pytest.raises(SQLGuardError, match="多语句"):
            guard_sql("SELECT 1; DROP TABLE orders")

    def test_ignores_keyword_inside_string_literal(self):
        """字符串字面量里的关键字不应被误杀"""
        result = guard_sql("SELECT * FROM t WHERE name = 'delete'")
        assert "delete" in result.sql

    def test_rejects_empty(self):
        """空语句拒绝"""
        with pytest.raises(SQLGuardError):
            guard_sql("   ")


class TestLimitEnforcement:
    """行数上限"""

    def test_injects_limit_when_absent(self):
        """无 LIMIT 时自动补齐"""
        result = guard_sql("SELECT * FROM orders", max_rows=500)
        assert result.limit_injected is True
        assert result.sql.rstrip().endswith("LIMIT 500")

    def test_keeps_smaller_existing_limit(self):
        """已有更小 LIMIT 时保持原样"""
        result = guard_sql("SELECT * FROM orders LIMIT 10", max_rows=500)
        assert result.limit_injected is False
        assert "LIMIT 10" in result.sql

    def test_clamps_oversized_limit(self):
        """超大 LIMIT 收紧到上限"""
        result = guard_sql("SELECT * FROM orders LIMIT 999999", max_rows=500)
        assert result.limit_injected is True
        assert "LIMIT 500" in result.sql
        assert "999999" not in result.sql


class TestIdentifierGuard:
    """表名/字段名校验"""

    @pytest.mark.parametrize("name", ["orders", "dwd_order_detail", "_tmp", "col_1"])
    def test_accepts_valid_identifiers(self, name):
        """常规标识符放行"""
        assert guard_identifier(name) == name

    @pytest.mark.parametrize(
        "name",
        [
            "t; DROP TABLE x",
            "orders--",
            "order`id",
            "order id",
            "1abc",
            "",
            "订单表",
            "a" * 65,
        ],
    )
    def test_rejects_invalid_identifiers(self, name):
        """含非法字符或超长的标识符拒绝"""
        with pytest.raises(SQLGuardError):
            guard_identifier(name)

    def test_error_message_includes_kind(self):
        """错误信息应带 kind，便于定位"""
        with pytest.raises(SQLGuardError, match="表名"):
            guard_identifier("bad name", kind="表名")


class TestGuardedSQLDataclass:
    """返回类型契约"""

    def test_returns_frozen_dataclass(self):
        """返回 GuardedSQL 且不可变，避免调用方误改校验结果"""
        result = guard_sql("SELECT 1")
        assert isinstance(result, GuardedSQL)
        with pytest.raises(AttributeError):
            result.sql = "DROP TABLE x"  # type: ignore[misc]
