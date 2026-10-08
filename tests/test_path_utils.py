"""
路径解析安全测试

path_utils.resolve_path 是文件读写的第一道（也是唯一一道）程序化边界。
模型输出的路径不可信：提示词注入可以让它返回 `../../.env` 或系统绝对路径，
因此本文件重点验证"越界必须被拒绝"，而不是只验证"正常路径能解析"。
"""

from pathlib import Path

import pytest

from app.utils.path_utils import PROJECT_ROOT, PathSecurityError, resolve_path


@pytest.fixture
def session_dir(tmp_path):
    """构造一个临时会话目录，模拟 output/session_xxx"""
    d = tmp_path / "session_abc"
    d.mkdir()
    return str(d)


class TestNormalResolution:
    """正常路径解析"""

    def test_resolves_filename_into_session_dir(self, session_dir):
        """裸文件名应解析到会话目录内"""
        result = Path(resolve_path("report.md", session_dir))
        assert result.parent == Path(session_dir).resolve()
        assert result.name == "report.md"

    def test_resolves_relative_subpath(self, session_dir):
        """会话目录内的相对子路径应保留层级"""
        result = Path(resolve_path("sub/chart.png", session_dir))
        assert Path(session_dir).resolve() in result.parents
        assert result.name == "chart.png"

    def test_strips_virtual_sandbox_prefix(self, session_dir):
        """模型常见的 /workspace 前缀应被剥离后落到会话目录"""
        result = Path(resolve_path("/workspace/report.md", session_dir))
        assert Path(session_dir).resolve() in result.parents
        assert result.name == "report.md"


class TestTraversalRejected:
    """越界路径必须被拒绝"""

    @pytest.mark.parametrize(
        "evil",
        [
            "../../../etc/passwd",
            "../.env",
            "../../app/config.py",
            "sub/../../../../secret.txt",
        ],
    )
    def test_rejects_relative_traversal(self, session_dir, evil):
        """相对路径穿越（..）必须抛出 PathSecurityError"""
        with pytest.raises(PathSecurityError):
            resolve_path(evil, session_dir)

    def test_rejects_unescaped_absolute_path(self, session_dir):
        """项目外的绝对路径必须拒绝（这是原实现直接放行的漏洞）"""
        with pytest.raises(PathSecurityError):
            resolve_path("C:/Windows/System32/drivers/etc/hosts", session_dir)

    def test_unix_style_path_mapped_into_session_dir(self, session_dir):
        """
        Windows 下以 / 开头且无盘符的路径视为沙箱虚拟路径，映射到会话目录。

        模型（尤其在类 Unix 环境中训练出来的模型）常输出 /etc/report.md 这类路径，
        这里的语义不是"访问系统目录"，而是"在沙箱内的工作路径"。因此该输入
        必须落在会话目录内，而不是被解析成真实的系统路径——这本身就是一道防线。
        """
        result = Path(resolve_path("/etc/shadow", session_dir))
        assert Path(session_dir).resolve() in result.parents
        assert result.name == "shadow"

    def test_rejects_empty_path(self, session_dir):
        """空路径直接拒绝，避免退化成当前工作目录"""
        with pytest.raises(PathSecurityError):
            resolve_path("", session_dir)

    def test_rejects_updated_traversal(self, session_dir):
        """updated/ 前缀不能成为穿越跳板"""
        with pytest.raises(PathSecurityError):
            resolve_path("updated/../app/config.py", session_dir)


class TestUploadDirAllowed:
    """上传目录属于合法范围"""

    def test_allows_updated_prefix(self, session_dir):
        """updated/ 下的用户附件应被放行"""
        result = Path(resolve_path("updated/attachment.txt", session_dir))
        # 应落在项目根的 updated 目录下
        assert result.parent == PROJECT_ROOT / "updated"
        assert result.name == "attachment.txt"


class TestErrorIsValueError:
    """异常类型契约"""

    def test_path_security_error_is_value_error(self):
        """PathSecurityError 继承 ValueError，便于调用方用宽类型兜住"""
        assert issubclass(PathSecurityError, ValueError)
