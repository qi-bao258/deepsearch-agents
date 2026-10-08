"""
文件路径解析工具

负责把模型或工具返回的虚拟路径、上传文件路径和相对路径统一转换为本地绝对路径，
并把可访问范围强制约束在允许的根目录之内。

安全边界（重要）：
模型输出的路径本质不可信——它可能被提示词注入诱导，返回 `../../.env`
或 `C:/Windows/System32/...` 这类越界路径。因此本模块不是"尽力解析"，
而是"解析 + 校验"：任何最终落在允许根目录之外的路径都会被拒绝。

允许的根目录有两个：
1. 当前会话目录 output/session_{id}/  —— 本任务的读写工作区
2. 项目根目录下的 updated/            —— 用户上传文件的落盘位置（只读语义）
其余位置（项目根之外、config/、app/ 源码目录等）一律拒绝。
"""

import os
from pathlib import Path
from typing import Optional

# 项目根目录：本文件位于 app/utils/path_utils.py，parents[2] 即项目根
PROJECT_ROOT = Path(__file__).parents[2].resolve()

# 用户上传文件的落盘目录，解析 `updated/...` 形式的路径时需要放行
UPLOAD_ROOT = (PROJECT_ROOT / "updated").resolve()


class PathSecurityError(ValueError):
    """路径越出允许范围时抛出"""


def _is_within(target: Path, root: Path) -> bool:
    """判断 target 是否位于 root 之内（含 root 自身）"""
    try:
        target.relative_to(root)
        return True
    except ValueError:
        return False


def _ensure_within_any(target: Path, roots: tuple[Path, ...]) -> None:
    """
    校验 target 必须落在 roots 之一内，否则抛出 PathSecurityError。

    这是本模块的核心防线：resolve() 已经把 `..` 和符号链接展开成真实路径，
    因此这里的比较不会被 `a/../b` 之类的写法绕过。
    """
    if not any(_is_within(target, root) for root in roots):
        raise PathSecurityError(
            f"路径超出允许范围：{target}（仅允许会话目录与 updated 上传目录）"
        )


def resolve_path(filename: str, session_dir: Optional[str] = None) -> str:
    """
    解析文件路径，并强制把结果约束在允许的根目录之内。

    :param filename: 模型、工具或用户传入的文件名/路径
    :param session_dir: 当前任务的会话目录
    :return: 解析后的绝对路径
    :raises PathSecurityError: 解析结果落在允许范围之外
    """
    if not filename or not str(filename).strip():
        raise PathSecurityError("文件路径为空")

    path = Path(filename)
    path_str = str(filename).replace("\\", "/")

    # 大模型常返回 /workspace、/mnt/data 这类沙箱路径，本地项目需要先剥离虚拟前缀
    for prefix in ["/workspace", "/mnt/data", "/home/user"]:
        if path_str.startswith(prefix):
            cleaned = path_str[len(prefix) :].lstrip("/")
            path = Path(cleaned)
            path_str = str(path).replace("\\", "/")
            break

    # 允许的根目录集合：会话目录（若有）+ 上传目录
    allowed_roots: list[Path] = []
    session_path: Optional[Path] = None
    if session_dir:
        session_path = Path(session_dir).resolve()
        allowed_roots.append(session_path)
    allowed_roots.append(UPLOAD_ROOT)
    roots_tuple = tuple(allowed_roots)

    # updated/ 用于存放用户上传文件，优先按项目根下的真实上传路径解析
    if "updated/" in path_str:
        idx = path_str.find("updated/")
        relative_part = path_str[idx:]
        # 先拼到项目根再 resolve，避免 `updated/../app/config.py` 绕过校验
        candidate = (PROJECT_ROOT / relative_part).resolve()
        _ensure_within_any(candidate, (UPLOAD_ROOT,))
        return str(candidate)

    if session_path is None:
        # 没有会话上下文时，只允许项目根内的路径；否则拒绝
        candidate = path.resolve()
        _ensure_within_any(candidate, (PROJECT_ROOT,))
        return str(candidate)

    session_name = session_path.name
    is_unix_abs = path_str.startswith("/")

    if path.is_absolute() or (os.name == "nt" and is_unix_abs):
        # Windows 下 "/xxx" 没有盘符，按会话目录内的相对路径处理
        if os.name == "nt" and is_unix_abs and not path.drive:
            full_path = (session_path / path_str.lstrip("/")).resolve()
        else:
            full_path = path.resolve()

        # 落在会话目录内：修正重复嵌套后返回
        if _is_within(full_path, session_path):
            return _fix_nested_session_path(full_path, session_path, session_name)

        # 落在上传目录内：作为用户附件放行
        if _is_within(full_path, UPLOAD_ROOT):
            return _fix_nested_session_path(full_path, session_path, session_name)

        # 其余绝对路径一律拒绝（原实现在此处直接 return，是真实的越界入口）
        raise PathSecurityError(
            f"路径超出允许范围：{full_path}（仅允许会话目录与 updated 上传目录）"
        )

    parts = path.parts

    # 避免模型把 session 名或 output 前缀重复拼到当前会话目录里
    if session_name in parts:
        candidate = (session_path / path.name).resolve()
        _ensure_within_any(candidate, roots_tuple)
        return str(candidate)

    if parts and parts[0] == "output":
        candidate = (session_path / path.name).resolve()
        _ensure_within_any(candidate, roots_tuple)
        return str(candidate)

    candidate = (session_path / path).resolve()
    _ensure_within_any(candidate, roots_tuple)
    return str(candidate)


def _fix_nested_session_path(
    full_path: Path,
    session_path: Path,
    session_name: str,
) -> str:
    """
    修正 session_xxx/session_xxx/file.md 这类重复嵌套路径
    """
    parts = full_path.parts
    for index in range(len(parts) - 1):
        if parts[index] == session_name and parts[index + 1] == session_name:
            return str(session_path / full_path.name)
    return str(full_path)
