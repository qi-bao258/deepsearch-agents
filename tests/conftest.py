"""
测试全局配置

把项目根目录加入 sys.path，保证 pytest 在任意工作目录下都能导入 app 包。
"""

import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))
