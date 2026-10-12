"""
深度研搜 · 安全护栏回归评测

目的：把"护栏到底拦住了什么"从注释里的承诺，变成可重复、可回归的基线数字。

与电商问数的评测集（衡量检索召回质量）不同，本项目评测的对象是
**安全护栏与路径解析的确定性行为**——它们都是纯函数，不依赖网络与模型，
因此可以在 CI 中每次提交都跑，成本近乎为零。

评测三类行为（全部为程序化判定，不依赖人工）：
1. sql        —— guard_sql 对整条 SQL 的放行 / 拒绝
2. identifier —— guard_identifier 对表名 / 字段名的放行 / 拒绝
3. path       —— resolve_path 对文件路径的放行 / 拒绝

用法：
    uv run python -m eval.run_eval

    # 指定评测集与报告输出路径
    uv run python -m eval.run_eval --golden eval/golden_set.yaml \
        --report eval/report.json
"""

import argparse
import json
import sys
import tempfile
from dataclasses import asdict, dataclass, field
from pathlib import Path

import yaml

from app.infra.sql_guard import SQLGuardError, guard_identifier, guard_sql
from app.utils.path_utils import PathSecurityError, resolve_path

# 安全护栏是确定性规则：任何一条既有判定被改变都属于回归。
# 因此门槛取 100%，与问数评测的召回率门槛（模糊质量）不同。
PASS_THRESHOLD = 1.0


@dataclass
class CaseResult:
    """单条评测用例的执行结果"""

    id: str
    kind: str
    category: str = ""
    expect: str = ""
    actual: str = ""
    passed: bool = False
    error: str | None = None


@dataclass
class EvalReport:
    """整体评测报告"""

    total: int = 0
    passed: int = 0
    pass_rate: float = 0.0
    cases: list[CaseResult] = field(default_factory=list)


def _materialize(raw) -> str:
    """把 repeat 形式的输入展开为实际字符串（用于长度边界用例）。"""
    if isinstance(raw, dict) and "repeat" in raw:
        spec = raw["repeat"]
        return spec["char"] * spec["times"]
    return raw


def _dispatch(kind: str, text: str, session_dir: str) -> tuple[str, bool | None]:
    """
    执行单条用例，返回 (判定, LIMIT 是否被注入)。

    判定为 "allow"（护栏放行）或 "deny"（护栏拒绝）。
    拒绝通过捕获护栏自身的异常类型识别，因此评测断言的是**真实代码路径**，
    而非另一套平行实现。
    """
    if kind == "sql":
        try:
            guarded = guard_sql(text)
        except SQLGuardError:
            return "deny", None
        return "allow", guarded.limit_injected

    if kind == "identifier":
        try:
            guard_identifier(text, kind="标识符")
        except SQLGuardError:
            return "deny", None
        return "allow", None

    if kind == "path":
        try:
            resolve_path(text, session_dir=session_dir)
        except PathSecurityError:
            return "deny", None
        return "allow", None

    raise ValueError(f"未知用例类型：{kind}")


def evaluate(cases: list[dict]) -> EvalReport:
    """逐条执行用例并汇总报告。单条失败不中断整轮评测。"""
    report = EvalReport(total=len(cases))

    # 建一个真实的临时会话目录，让 path 类用例有合法的放行基准
    with tempfile.TemporaryDirectory(prefix="eval_session_") as session_dir:
        for case in cases:
            result = CaseResult(
                id=case["id"],
                kind=case["kind"],
                category=case.get("category", ""),
                expect=case["expect"],
            )
            try:
                text = _materialize(case["input"])
                verdict, limit_injected = _dispatch(case["kind"], text, session_dir)
                result.actual = verdict
                passed = verdict == case["expect"]
                # sql 类用例可额外断言 LIMIT 行为
                if passed and "expect_limit_injected" in case:
                    passed = limit_injected == case["expect_limit_injected"]
                result.passed = passed
            except Exception as e:  # 单条异常不应中断整轮评测
                result.error = f"{type(e).__name__}: {e}"
                result.actual = "error"

            report.cases.append(result)

    report.passed = sum(1 for c in report.cases if c.passed)
    n = len(report.cases) or 1
    report.pass_rate = report.passed / n
    return report


def render_console(report: EvalReport) -> str:
    """渲染控制台可读报告"""
    lines = [
        "",
        "=" * 72,
        "深度研搜 · 安全护栏回归评测报告",
        "=" * 72,
        f"用例总数    : {report.total}",
        f"通过用例数  : {report.passed}",
        f"通过率      : {report.pass_rate:.1%}",
        "-" * 72,
        f"{'用例':<8}{'类型':<12}{'期望':<8}{'实际':<8}{'结果':<8}分类",
    ]
    for c in report.cases:
        status = "通过" if c.passed else ("异常" if c.error else "未过")
        lines.append(
            f"{c.id:<8}{c.kind:<12}{c.expect:<8}{c.actual:<8}{status:<8}{c.category}"
        )
        if c.error:
            lines.append(f"    异常: {c.error}")
    lines.append("=" * 72)
    return "\n".join(lines)


def load_golden_set(path: Path) -> list[dict]:
    """加载评测集"""
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, list):
        raise ValueError(f"评测集格式错误，应为列表：{path}")
    return data


def main() -> int:
    parser = argparse.ArgumentParser(description="深度研搜安全护栏回归评测")
    parser.add_argument(
        "--golden",
        default=str(Path(__file__).parent / "golden_set.yaml"),
        help="评测集路径",
    )
    parser.add_argument(
        "--report",
        default=str(Path(__file__).parent / "report.json"),
        help="报告输出路径",
    )
    args = parser.parse_args()

    cases = load_golden_set(Path(args.golden))
    report = evaluate(cases)
    print(render_console(report))

    report_path = Path(args.report)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        json.dumps(asdict(report), ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"JSON 报告已写入：{report_path}")

    # 通过率低于门槛时以非零码退出，便于接入 CI 做回归门禁
    return 0 if report.pass_rate >= PASS_THRESHOLD else 1


if __name__ == "__main__":
    sys.exit(main())
