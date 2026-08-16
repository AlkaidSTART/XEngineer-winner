# Page2Frame 审查报告

## 一句话判断

Python FastAPI 实现的小说转剧本 AI 工具，核心创新是 Story Bible 一致性引擎（LLM 抽取增量 + 代码确定性合并 + 冲突检测），工程规范、测试充分、安全自实现到位，是五个项目中产品完成度与技术深度结合最好的一个。

## 项目地图

| 维度 | 信息 |
|------|------|
| 项目名称 | Page2Frame |
| 类型 | Web 全栈应用（小说转剧本+分镜） |
| 语言/框架 | Python 3.11 / FastAPI / SQLModel / React+Vite |
| 构建工具 | Poetry (backend) / npm (frontend) |
| 源码规模 | 42 个 Python 文件（4,038 行）+ 25 个测试文件（2,471 行）+ 40 个前端文件（3,981 行） |
| 核心入口 | `backend/app/main.py`（FastAPI 应用） |
| 外部服务 | OpenAI 兼容 LLM API、可选 vLLM 本地推理、可选 diffusers 本地图像生成 |
| 部署形态 | Docker Compose 一键部署 |
| 仓库状态 | 1 次 git commit |

**目录结构：**
```
backend/
├── app/
│   ├── main.py                      # FastAPI 应用入口
│   ├── config.py                    # 配置管理（pydantic-settings）
│   ├── pipeline/
│   │   ├── orchestrator.py          # 端到端流水线编排（140行）
│   │   ├── bible_extract.py         # Story Bible 抽取+合并（222行，核心创新）
│   │   ├── scene_extract.py         # 场景抽取
│   │   ├── length_strategy.py       # 长度策略
│   │   └── quality_report.py        # 质量报告
│   ├── services/
│   │   ├── auth.py                  # 自实现认证（156行，pbkdf2+HMAC-SHA256）
│   │   ├── job.py                   # 任务管理
│   │   ├── collaboration.py         # 协作分享
│   │   └── export.py                # 导出
│   ├── llm/client.py                # LLM 客户端封装
│   ├── models/                      # 数据模型（bible/account/job）
│   ├── repository/db.py             # SQLModel 数据访问
│   └── prompts/                     # LLM 提示词模板
├── pyproject.toml                   # Poetry 依赖管理
└── tests/                           # 25 个测试文件（2,471行）
frontend/                            # React + Vite 前端（40文件，3,981行）
docker-compose.yml                   # 一键部署
.gitignore                           # 完善的忽略规则
```

## 产品与商业场景

**目标用户：** 小说作者、编剧、影视/动画/漫画创作者、AI 辅助创作爱好者。

**场景痛点：** 长篇小说改编为剧本/分镜时，人物设定一致性难以维护（角色外貌、性格、状态在多章节中容易矛盾），手动梳理 Bible 耗时且易遗漏，章节间连续性追踪困难。

**输入/处理/输出/反馈闭环：**
- 输入：用户上传小说文本（多章节）→ 创建 Job
- 处理：流水线串行处理每章：Bible 增量抽取 → 冲突检测 → 场景边界识别 → 场景抽取 → YAML 组装
- 输出：结构化剧本（三栏编辑器：原文/剧本/分镜）+ 质量报告 + Story Bible
- 反馈：用户在编辑器中修改 → 可重新触发流水线；质量仪表盘展示一致性评分

**独特价值：** Story Bible 一致性引擎——这是项目的核心技术创新。两段式设计（LLM 抽取增量 + 代码确定性合并），将一致性判断从"全靠 LLM"变为"代码确定性检测"，保证可复现、不幻觉。具体包括：
- 规范名锁定：已有规范名不可改，新章只补别名/补空字段
- 视觉锚点冲突检测：同一 aspect 值不一致 → 记 conflict，不静默覆盖
- 状态时间线追加：角色状态逐章追加，永不冲突
- 别名联合匹配：避免规范名漂移造成重复角色

**商业化分析：**
- 付费方：创作者/工作室（LLM API 成本由接入方承担，工具本身免费）
- 获客渠道：写作社区 + 影视制作论坛 + 开源社区
- 交付成本：Docker 一键部署，本地优先可选（vLLM + diffusers 本地推理）
- 持续使用理由：长篇小说改编周期内持续使用，Bible 滚动积累价值

## 架构拆解

### 文字架构图

```
用户上传小说 → 创建 Job → Pipeline.orchestrate()
    │
    ├─[1] ingest(chapters) → 解析章节
    │
    ├─[2] length_strategy → 章节长度策略（控制 LLM 输入）
    │
    └─[3] 逐章串行处理：
        ├── update_bible(chapter_text, bible, chapter)
        │   ├── extract_bible_delta() → LLM 抽取本章增量
        │   │   (注入现有 Bible 摘要作为约束)
        │   └── merge_delta() → 代码确定性合并
        │       ├── _merge_character(): 别名并集+空字段填充+视觉锚点冲突检测+状态追加
        │       ├── 地点去重补充
        │       ├── 术语去重补充
        │       ├── 时间线锚点追加
        │       ├── 关系补充
        │       └── LLM 主动报告冲突去重
        │
        ├── conflict_detection → 冲突汇总
        │
        ├── scene_boundary → 场景边界识别
        │
        └── scene_extraction → 场景内容抽取
    │
    ├─[4] YAML 组装 → 结构化剧本
    │
    └─[5] quality_report → 质量报告（冲突数/覆盖率/一致性评分）
    │
    v
SSE 推送进度 → 三栏编辑器展示 → 质量仪表盘
```

### 请求追踪：一次完整的小说转剧本

1. 用户上传小说 → `POST /api/jobs` → `JobService.create()` → SQLite 存储
2. `Pipeline.orchestrate(chapters, progress_callback)`（`orchestrator.py:140`）启动
3. `ingest(chapters)` 解析章节文本
4. `length_strategy()` 决定每章处理策略
5. 逐章串行：
   - `update_bible(chapter_text, bible, chapter)`（`bible_extract.py:209-221`）
     - `extract_bible_delta()`：LLM 从本章抽取增量，注入现有 Bible 摘要作为约束（`bible_extract.py:50-66`）
     - `merge_delta()`：代码确定性合并到 Bible（`bible_extract.py:137-206`）
       - 角色合并：`_merge_character()` 处理别名并集、空字段填充、视觉锚点冲突检测（保留旧值记 conflict）、状态时间线追加（`bible_extract.py:69-112`）
       - 地点/术语去重补充、时间线追加、关系补充
       - LLM 主动报告冲突去重合并
   - `conflict_detection()` 汇总冲突
   - `scene_boundary()` 识别场景边界
   - `scene_extraction()` 抽取场景内容
6. YAML 组装 → 结构化剧本输出
7. `quality_report()` 生成质量报告（冲突数/覆盖率/一致性评分）
8. SSE 推送进度 → 前端三栏编辑器展示

### 关键设计决策

- **两段式 Bible 一致性引擎**（`bible_extract.py`）：LLM 抽取增量 + 代码确定性合并，将一致性判断从"全靠 LLM"变为"代码确定性检测"，保证可复现——这是项目的核心技术深度
- **自实现认证**（`auth.py`）：pbkdf2_hmac 口令哈希 + HMAC-SHA256 签名 token，零外部依赖，`hmac.compare_digest` 防时序侧信道
- **RBAC 协作权限**（`auth.py:143-155`）：owner/editor/viewer 三级，`require_role()` 区分 404（无权不泄露存在性）和 403（有权但级别不够）
- **本地优先可选**（`pyproject.toml`）：vLLM + diffusers 可选依赖，支持完全本地推理
- **SSE 进度推送**（`orchestrator.py`）：`progress_callback` 回调机制，流水线进度实时推送前端
- **完善的安全实践**（`.gitignore`）：排除 .env、*.db、模型权重、samples，无密钥泄露

## 工程评分

| 维度 | 分数 | 证据 |
|------|------|------|
| 产品完成度 | 4 | 流水线完整（Bible→冲突→场景→YAML→质量报告），三栏编辑器+质量仪表盘+协作系统 |
| 架构边界 | 4 | pipeline/services/models/repository/llm 分层清晰，关注点分离 |
| 可维护性 | 4 | 模块化好，命名规范，docstring 充分，配置外部化（pydantic-settings） |
| 可测试性 | 4 | 25 个测试文件 2,471 行，覆盖核心流水线和认证，测试占比 61% |
| 可观测性 | 3 | SSE 进度推送 + 质量报告；但无结构化日志框架，无外部指标导出 |
| 安全隐私 | 5 | 自实现认证（pbkdf2+HMAC+compare_digest），RBAC 404/403 区分，.gitignore 完善，无密钥泄露 |
| 性能并发 | 3 | 章节串行处理（Bible 依赖前序），SSE 推送进度；但无并行处理空间（串行是业务需求） |
| 资源释放 | 3 | SQLModel session 用 context manager；但 LLM client 无显式关闭 |
| 成本控制 | 3 | 长度策略控制 LLM 输入；但无 token 预算，无缓存，无速率限制 |
| 部署恢复 | 4 | Docker Compose 一键部署；本地优先可选（vLLM+diffusers） |
| 文档 | 4 | README 详尽（Story Bible 引擎/三栏编辑器/质量仪表盘/协作/Docker）；与代码一致 |
| 上手难度 | 3 | Docker 一键启动，但小说转剧本概念需要理解成本 |

### 问题分级

**阻断级：** 无

**重要级：**
- 章节串行处理（Bible 依赖前序结果），长小说处理时间长，无并行优化空间（串行是业务约束）
- 无 LLM 调用缓存，重复处理同一章节会产生重复 API 调用和成本
- 无速率限制，多用户并发时 LLM API 成本不可控

**一般级：**
- 自实现认证虽正确但未经安全审计，建议生产环境使用成熟库（python-jose/PyJWT）
- SQLite 单文件存储，生产环境可能需要迁移到 PostgreSQL
- LLM client 无连接池/重试机制（取决于 httpx 默认行为）
- 质量报告的"一致性评分"算法未深入审查，评分标准可能需要调优
- 前端 40 个文件 3,981 行集中审查未做，React 组件复杂度未评估

**建议级：**
- 增加 LLM 调用缓存（按章节内容 hash）
- 增加速率限制中间件
- 支持断点续传（章节级 checkpoint）
- 增加 Bible 手动编辑/冲突解决 UI

## 优点

1. **Story Bible 一致性引擎**（`bible_extract.py`）：两段式设计（LLM 抽取增量 + 代码确定性合并）是项目的核心技术创新。将一致性判断从"全靠 LLM"变为"代码确定性检测"，保证可复现、不幻觉。视觉锚点冲突检测（保留旧值记 conflict 不静默覆盖）、规范名锁定、状态时间线追加、别名联合匹配，构成完整的一致性维护机制
2. **自实现认证的安全实践**（`auth.py`）：pbkdf2_hmac 口令哈希 + HMAC-SHA256 签名 token + `hmac.compare_digest` 防时序侧信道，零外部依赖。RBAC 三级权限（owner/editor/viewer）+ `require_role()` 区分 404/403（不泄露资源存在性），安全设计周到
3. **测试覆盖充分**：25 个测试文件 2,471 行，覆盖核心流水线和认证，测试占比 61%
4. **完善的安全实践**：`.gitignore` 排除 .env/*.db/模型权重/samples，无密钥泄露
5. **本地优先可选**：vLLM + diffusers 可选依赖，支持完全本地推理，降低 API 成本和隐私风险
6. **SSE 进度推送**：`progress_callback` 回调机制，流水线进度实时推送前端
7. **Docker 一键部署**：完整编排，降低部署门槛
8. **README 与代码一致**：文档准确描述实际功能，无虚报

## 缺点风险与改进优先级

| 优先级 | 问题 | 影响 | 建议 |
|--------|------|------|------|
| P1 | 无 LLM 调用缓存 | 重复处理产生重复成本 | 按章节内容 hash 缓存 |
| P1 | 无速率限制 | 多用户并发 API 成本不可控 | 增加速率限制中间件 |
| P2 | 自实现认证未审计 | 潜在安全风险 | 生产环境考虑成熟库或安全审计 |
| P2 | SQLite 单文件 | 生产并发受限 | 迁移到 PostgreSQL |
| P2 | 无断点续传 | 长流水线中断需重跑 | 章节级 checkpoint |
| P3 | LLM client 无重试 | API 偶发失败导致流水线中断 | 增加指数退避重试 |
| P3 | 质量评分算法未审查 | 评分标准可能需调优 | 审查并文档化评分逻辑 |

## 复用性矩阵

| 部分 | 评级 | 说明 |
|------|------|------|
| Story Bible 一致性引擎 | 可直接复用 | 两段式（LLM 抽取 + 代码合并）+ 冲突检测，可迁移到任何需要跨章节/跨文档一致性的场景 |
| 自实现认证模块 | 可直接复用 | pbkdf2 + HMAC-SHA256 + RBAC，可迁移到任何 FastAPI 项目 |
| 流水线编排框架 | 可直接复用 | 串行处理 + progress_callback + 质量报告的编排模式 |
| LLM 客户端封装 | 可直接复用 | OpenAI 兼容 + complete_json 接口 |
| Docker 部署编排 | 可直接复用 | 一键部署模板 |
| 三栏编辑器前端 | 改造后复用 | React+Vite 组件，需适配具体业务 |
| 质量报告生成 | 改造后复用 | 框架可复用，评分逻辑需适配 |

**复用评分：** 技术 4 / 产品 4 / 商业 3

## 值得学习的内容

1. **【进阶者】两段式一致性引擎**：LLM 抽取增量 + 代码确定性合并的设计模式——将需要"判断"的部分交给 LLM，将需要"确定性"的部分交给代码。这是 LLM+传统代码混合架构的优秀范式，可迁移到任何需要跨文档一致性的场景（`bible_extract.py`）
2. **【进阶者】自实现认证的安全实践**：pbkdf2_hmac + HMAC-SHA256 + `hmac.compare_digest` 防时序侧信道 + RBAC 404/403 区分——零依赖实现完整认证，适合理解认证原理（`auth.py`）
3. **【初学者】FastAPI + SQLModel + pydantic-settings 全栈模板**：配置管理 + 数据模型 + API 路由的标准组织方式
4. **【初学者】Docker Compose 全栈一键部署**：backend + frontend + 数据库的完整编排
5. **【可复刻实验】** Story Bible 一致性引擎的冲突检测机制——视觉锚点冲突（保留旧值记 conflict 不覆盖）、规范名锁定、状态时间线追加、别名联合匹配，可迁移到知识图谱构建、角色管理、设定维护等场景
6. **【可迁移模式】** `progress_callback` 回调 + SSE 推送的长任务进度反馈模式
7. **【可迁移模式】** 本地优先可选依赖（vLLM + diffusers 作为 optional deps），降低 API 成本和隐私风险

```yaml
project: Page2Frame
one_line_judgment: "Python FastAPI小说转剧本工具，Story Bible一致性引擎(LLM抽取+代码确定性合并)是核心创新，工程规范测试充分安全到位，五个项目中产品完成度与技术深度结合最好"
product_type: "Web全栈应用（小说转剧本+分镜）"
target_users: ["小说作者", "编剧", "影视/动画/漫画创作者", "AI辅助创作爱好者"]
core_loop: "上传小说 → 流水线逐章串行(Bible增量抽取+冲突检测+场景抽取) → YAML剧本组装 → 三栏编辑器+质量仪表盘 → 协作分享"
architecture_style: "FastAPI分层架构 + 两段式一致性引擎(LLM抽取+代码合并) + SSE进度推送 + 本地优先可选"
stack: ["Python 3.11", "FastAPI", "SQLModel", "Pydantic", "OpenAI SDK", "React", "Vite", "Docker Compose", "可选vLLM", "可选diffusers"]
strongest_patterns: ["两段式Bible一致性引擎(LLM抽取增量+代码确定性合并)", "视觉锚点冲突检测(保留旧值记conflict不覆盖)", "规范名锁定+别名联合匹配", "状态时间线追加", "自实现认证(pbkdf2+HMAC-SHA256+compare_digest防时序)", "RBAC三级权限(404/403区分)", "SSE进度推送(progress_callback)", "本地优先可选(vLLM+diffusers)", "Docker一键部署", "完善.gitignore无密钥泄露"]
main_risks: ["章节串行处理耗时长(业务约束)", "无LLM调用缓存", "无速率限制", "自实现认证未审计", "SQLite单文件", "无断点续传"]
business_scenarios: ["长篇小说转剧本", "影视/动画分镜制作", "漫画脚本生成", "AI辅助创作", "跨章节角色一致性维护", "知识图谱增量构建"]
reusable_assets: ["Story Bible一致性引擎", "自实现认证模块", "流水线编排框架", "LLM客户端封装", "Docker部署编排", "三栏编辑器前端", "质量报告生成框架"]
non_reusable_parts: ["SQLite单文件存储(应迁移PostgreSQL)", "质量评分算法(需适配)", "前端组件(需适配业务)"]
scores:
  product: 4
  architecture: 4
  engineering: 4
  reuse: 4
  commercialization: 3
evidence: ["backend/app/pipeline/orchestrator.py:1-140(端到端流水线编排)", "backend/app/pipeline/bible_extract.py:50-66(LLM抽取增量)", "backend/app/pipeline/bible_extract.py:69-112(_merge_character视觉锚点冲突检测)", "backend/app/pipeline/bible_extract.py:137-206(merge_delta确定性合并)", "backend/app/pipeline/bible_extract.py:209-221(update_bible滚动更新)", "backend/app/services/auth.py:30-48(pbkdf2口令哈希+compare_digest)", "backend/app/services/auth.py:60-85(HMAC-SHA256签名token)", "backend/app/services/auth.py:143-155(require_role 404/403区分)", "backend/pyproject.toml(可选依赖vLLM/diffusers)", ".gitignore(完善排除规则)", "backend/tests/(25个测试文件2471行)"]
confidence: "高"
```
