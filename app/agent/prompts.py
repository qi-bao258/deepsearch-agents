"""
提示词配置加载模块

负责读取 app/prompt/prompts.yml 中的主智能体和子智能体配置
后续组装 DeepAgent 时，可以直接复用 main_agent_content 和 sub_agents_content
"""

from pathlib import Path
from typing import Any

import yaml

from app.infra.log import logger


def load_yaml(file_path: Path) -> dict[str, Any]:
    """
    加载 YAML 配置文件

    :param file_path: YAML 文件路径
    :return: YAML 解析后的字典
    """
    with open(file_path, "r", encoding="utf-8") as f:
        # safe_load 只按数据解析 YAML，避免 yaml.load 可能触发的对象构造风险
        return yaml.safe_load(f)


# 当前文件位于 app/agent/prompts.py，parents[1] 即 app 目录
app_root_path = Path(__file__).parents[1]
yaml_file_path = app_root_path / "prompt" / "prompts.yml"

prompt_yaml_content = load_yaml(yaml_file_path)

# 主智能体提示词配置
main_agent_content = prompt_yaml_content["main_agent"]

# 子智能体配置集合，包含 name、description 和 system_prompt
sub_agents_content = prompt_yaml_content["sub_agents"]

# 原实现在此处 print(sub_agents_content)，属于模块导入副作用：
# 任何 import app.agent.prompts 的代码都会向 stdout 打印大段提示词，
# 既不便于测试（污染断言输出），也会把提示词内容泄漏到日志采集系统。
# 改为 debug 级别：默认不输出，需要排查时把日志级别调到 DEBUG 即可看到。
logger.debug(f"已加载提示词配置：主智能体 + {len(sub_agents_content)} 个子智能体")
