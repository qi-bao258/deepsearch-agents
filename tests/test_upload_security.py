"""
上传接口安全测试

/api/upload 是最直接的攻击面：filename 与 thread_id 都由客户端提供，
且都会参与服务端路径拼接。本文件验证两者都无法用于路径穿越。
"""

import pytest
from fastapi.testclient import TestClient

from app.api import server as server_module


@pytest.fixture
def client(tmp_path, monkeypatch):
    """
    把 updated 目录指向临时目录后构造 TestClient，
    避免测试污染项目真实的 updated/。
    """
    fake_updated = tmp_path / "updated"
    fake_updated.mkdir()
    monkeypatch.setattr(server_module, "updated_dir", fake_updated)
    return TestClient(server_module.app), fake_updated


class TestUploadPathTraversal:
    """文件名路径穿越"""

    def test_normal_filename_is_saved(self, client):
        """常规文件名正常落盘"""
        c, updated = client
        resp = c.post(
            "/api/upload",
            files={"files": ("report.txt", b"hello", "text/plain")},
            data={"thread_id": "s1"},
        )
        assert resp.status_code == 200
        assert resp.json()["files"] == ["report.txt"]
        assert (updated / "session_s1" / "report.txt").read_bytes() == b"hello"

    @pytest.mark.parametrize(
        "evil_name",
        [
            "../../../evil.txt",
            "..\\..\\evil.txt",
            "sub/../../evil.txt",
        ],
    )
    def test_traversal_filename_is_neutralized(self, client, evil_name):
        """
        带目录成分的文件名必须被剥离为纯文件名。

        Path(name).name 只保留最后一段，因此 `../../evil.txt` 会变成 `evil.txt`，
        最终仍落在会话目录内，而不是逃逸到项目源码目录。
        """
        c, updated = client
        resp = c.post(
            "/api/upload",
            files={"files": (evil_name, b"payload", "text/plain")},
            data={"thread_id": "s2"},
        )
        assert resp.status_code == 200
        saved = resp.json()["files"]
        # 保存名不得包含任何路径分隔符
        for name in saved:
            assert "/" not in name
            assert "\\" not in name

        # 明确验证没有文件逃逸到 updated 之外
        escaped = list(updated.parent.glob("evil.txt"))
        assert escaped == []


class TestUploadThreadIdValidation:
    """thread_id 校验"""

    @pytest.mark.parametrize(
        "evil_thread",
        ["../escape", "a/../../b", "..\\win", "x/../y"],
    )
    def test_rejects_malicious_thread_id(self, client, evil_thread):
        """含路径分隔符或 .. 的 thread_id 必须被拒绝"""
        c, _ = client
        resp = c.post(
            "/api/upload",
            files={"files": ("a.txt", b"x", "text/plain")},
            data={"thread_id": evil_thread},
        )
        assert resp.status_code == 400
        assert resp.json()["code"] == 10001


class TestUploadSizeLimit:
    """文件大小上限"""

    def test_rejects_oversized_file(self, client, monkeypatch):
        """超过上限的文件应被拒绝且不留残片"""
        c, updated = client
        # 把上限压到 1KB，避免测试真的构造 50MB 数据
        monkeypatch.setattr(server_module, "MAX_UPLOAD_SIZE", 1024)

        resp = c.post(
            "/api/upload",
            files={"files": ("big.bin", b"x" * 5000, "application/octet-stream")},
            data={"thread_id": "s3"},
        )
        # FILE_ERROR 映射到 500（服务端处理失败）
        assert resp.status_code == 500
        assert resp.json()["code"] == 50001
        # 超限文件不应留在磁盘上
        leftover = list((updated / "session_s3").glob("big.bin"))
        assert leftover == []
