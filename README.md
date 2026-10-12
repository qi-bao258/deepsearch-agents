<div align="center">
  <h1>「深度研搜」对话式多智能体研究系统</h1>
  <p>
    <img src="https://img.shields.io/badge/DeepAgents-0.5.7-1C3C3C" alt="DeepAgents">
    <img src="https://img.shields.io/badge/FastAPI-WebSocket-009688?logo=fastapi&logoColor=white" alt="FastAPI">
    <img src="https://img.shields.io/badge/LangGraph-1.1.10-1C3C3C" alt="LangGraph">
    <img src="https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white" alt="Docker">
  </p>
</div>

## 项目介绍

「深度研搜」是一个面向深度研究场景的对话式多智能体系统。用户提出一个研究问题后，系统由主智能体统一调度多个专家子智能体并行检索不同来源的信息，最终汇总为结构化的回答、Markdown 或 PDF 交付。

系统采用「一主三从」的编排架构：

- **主智能体（调度中心）**：负责解析任务、规划子智能体分工、汇总各子智能体结果，并持有文件交付类工具，可将最终结论生成为 Markdown 或 PDF。
- **网络搜索子智能体**：基于 Tavily 检索公开网络信息。
- **数据库查询子智能体**：连接本地 MySQL 教学库，执行表结构探查、数据预览与 SQL 查询。
- **知识库子智能体**：接入 RAGFlow 私有知识库，完成临时会话问答与知识检索。

此外，系统支持读取用户上传的附件（PDF / Word / Markdown），按 `session_id` 隔离每个会话的执行上下文与输出目录，并通过 WebSocket 向前端实时推送工具调用、子智能体调度与最终结果。

后端、前端与 MySQL 均由 Docker Compose 编排，通过 `启动深度研搜.ps1` 一键拉起。

## 项目技术栈

| 层次 | 技术 |
| ---- | ---- |
| 多智能体框架 | DeepAgents、LangGraph、LangChain |
| Web 框架 | FastAPI（REST + WebSocket 实时推送） |
| 网络检索 | Tavily Search API |
| 数据库 | MySQL（`mysql-connector-python`，本地教学库） |
| 私有知识库 | RAGFlow（`ragflow-sdk`） |
| 文件处理 | pypdf、python-docx、markdown、reportlab、openpyxl、pandas |
| 文档交付 | Markdown 生成 + PDF 转换 |
| 会话管理 | LangGraph Checkpointer（内存记忆） |
| 前端 | React + TypeScript + Vite |
| 部署 | Docker Compose + Nginx + PowerShell 一键启停脚本 |
| 工程规范 | Ruff、pre-commit、pytest、pytest-asyncio、pytest-cov |

## 项目结构

```text
deepsearch-agents/
├── app/
│   ├── agent/                  # 多智能体编排
│   │   ├── main_agent.py       # 主智能体（调度中心，惰性单例构建）
│   │   ├── llm.py              # 大模型客户端
│   │   ├── prompts.py          # 主智能体提示词
│   │   └── subagents/          # 专家子智能体
│   │       ├── network_search_agent.py   # 网络搜索子智能体
│   │       ├── database_query_agent.py   # 数据库查询子智能体
│   │       └── knowledge_base_agent.py   # 知识库子智能体（RAGFlow）
│   ├── api/                    # FastAPI 接口层
│   │   ├── server.py           # 接口与 WebSocket 路由
│   │   ├── context.py          # 会话上下文管理
│   │   ├── monitor.py          # 事件监控与推送
│   │   └── exception.py        # 全局异常处理
│   ├── tools/                  # 工具层
│   │   ├── tavily_tool.py      # 网络搜索工具
│   │   ├── db_tools.py         # 数据库查询工具
│   │   ├── ragflow_tools.py    # 知识库工具
│   │   ├── markdown_tools.py   # Markdown 生成
│   │   ├── pdf_tools.py        # PDF 转换
│   │   └── upload_file_read_tool.py  # 附件读取
│   ├── ragflow/                # RAGFlow 接入配置
│   ├── infra/                  # 日志、SQL 护栏等基础设施
│   └── utils/                  # 路径、文档转换等工具函数
├── docker/                     # Docker Compose 编排（MySQL + 后端 + 前端）
│   ├── docker-compose.yaml
│   ├── docker-compose.net.yaml
│   └── docker-compose.app.yaml
├── frontend/                   # React 前端
├── docs/                       # 演示截图与知识库种子数据
├── examples/                   # 示例文档
├── tests/                      # 单元测试
├── pyproject.toml              # 依赖与工具配置
├── Dockerfile                  # 后端镜像
├── 启动深度研搜.ps1             # 一键启动脚本
└── 停止深度研搜.ps1             # 一键停止脚本
```

## 快速开始

1. 安装并启动 [Docker Desktop](https://www.docker.com/products/docker-desktop/)。
2. 复制环境变量模板并填入密钥：

```bash
cp .env.example .env   # 编辑 .env，设置 OPENAI_API_KEY、LLM_QWEN_MAX、TAVILY_API_KEY 等
```

3. 双击 `启动深度研搜.ps1`，脚本会自动拉起 Docker 引擎、启动全部容器、等待后端就绪并打开浏览器：

```text
前端界面：http://localhost:5174
接口文档：http://localhost:8001/docs
健康检查：http://localhost:8001/health/ready
```

4. 停止服务：双击 `停止深度研搜.ps1`。

> 首次运行会构建镜像（约 1-4 分钟），之后日常启动直接复用镜像。容器由 Docker 守护进程托管，关闭脚本窗口不会停止服务。

## License

[MIT](LICENSE)
