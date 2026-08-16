# PlotPulse（剧脉）项目审查报告

## 一句话判断

PlotPulse 是一个工程素养明显高于同期演示项目的小说改剧本工作台，核心创新在于"LLM 当零件、确定性引擎守全局状态"的分层架构与砍戏影响可视化，但作为单机本地 MVP，其商业化和多用户扩展能力尚未验证。

## 项目地图

- 项目根目录：`/Users/allure/Desktop/七牛云项目/PlotPulse`
- 项目名称：剧脉 PlotPulse（议题三：AI 小说转剧本工具）
- 语言与框架：
  - 前端：React 19 + Vite 7 + TypeScript（`web/`，入口 `web/src/main.tsx` → `App.tsx`）
  - 后端：Python 3.12 + FastAPI + Pydantic（`server/app/main.py:12` 的 `create_app()`）
  - LLM：七牛云 AI 大模型推理 API（OpenAI 兼容，默认 `deepseek-v3`，`server/app/llm/client.py:27` `QiniuChatClient`）
  - 状态：YAML/JSON 文档族 + Pydantic Schema（`server/app/store/documents.py` `DocumentStore`）
  - 测试：Vitest（前端）+ pytest（后端）
- 运行入口：`npm run dev`（concurrently 同时启动 `uvicorn server.app.main:app` 和 Vite dev server）
- 主要可执行路径：
  - 后端 API：`/api/extractions/*`（抽取）、`/api/story-map`、`/api/cut-impact`、`/api/projects`、`/api/foreshadow-graph`、`/api/stories`、`/api/health`
  - 前端三栏工作台：`ImportRail` / `WorkbenchRail` / `GenerationRail`（`web/src/App.tsx:632/799/1030`）
- 边界识别：
  - 前端 `web/`：React 三栏工作台、故事画布、砍戏预警、剧本交付
  - 后端 `server/app/`：`api/`（路由）、`engine/`（确定性引擎，不调用 LLM）、`llm/`（七牛云调用）、`models/`（Pydantic 文档模型）、`store/`（文档族存储）
  - 契约 `shared/contracts/`：从 Pydantic 导出的 JSON Schema（bible/project/screenplay/reports/health）
  - 数据 `data/`：本地运行时文档族（YAML/JSON 默认不提交）
- 待验证：README 第 211-216 行声称"14 个合并 PR、47 个非 merge commits"，但 `git log` 实际只有 1 个 commit（`ed10d3c 增加B站视频链接`）。README 第 8 行自述"最后一个 commit 是因为一直在等待上传到 b 站的视频审核完毕，其余所有 commit 时间都在 6 月8 日以前"，合理推断历史被压缩/重写，开发过程声明无法从 git 验证。

## 产品与商业场景

- 目标用户：独立编剧、认真改编自己作品的小说作者（README 第 18 行；`docs/retrospective.md` 第 2 节明确"服务严肃改编者而非流量写手"）。
- 场景痛点：长篇小说改剧本时，人物弧光、伏笔回收、情节线跨章节分布，单次 prompt 难以稳定维护全局状态；删一场戏可能让第三章的伏笔回收悬空（`docs/retrospective.md` 第 1 节）。
- 输入/处理/输出/反馈闭环：
  - 输入：3 章以上 TXT 小说 + 改编 brief（媒介/长度/忠实度）
  - 处理：分块预检 → LLM 逐 chunk 抽取 beats/人物/情节线/伏笔 → 跨块合并 → 确定性投影与依赖图 → 编剧取舍 → LLM 场景生成
  - 输出：干净的 `screenplay.yaml`（只含 `schema_version/title/scenes`）+ `screenplay.txt` + 过程报告
  - 反馈：勾选待删 beat 实时显示"高光丢失/伏笔悬空/情节线受损/级联影响"（`web/src/App.tsx:880` `ImpactRibbon`）
- 独特价值：砍戏影响可视化是本项目最核心的差异化能力（README 第 24 行；`server/app/engine/cut_impact.py:75` `analyze_cut_impact`）。
- 最可能打动评委的体验瞬间：勾选一个 beat 试删，影响指标实时跳变，并能看见级联波及的 beat（`web/src/App.tsx:985` `impactStateFor`）。
- 商业化分析（基于产品形态的假设，无市场数据）：
  - 付费方/使用者/决策者：独立编剧个人付费；小型影视改编团队可作为协作工具
  - 获客渠道：编剧社区、网文作者社区、实训营展示
  - 交付成本：依赖七牛云 LLM token 成本，长文本抽取多 chunk 串行调用，单次改编成本可观
  - 持续使用理由：每部新小说都需要重新抽取，但有复用价值的是 schema 与引擎
  - 合规/隐私：上传小说正文走第三方 LLM，版权与隐私敏感
  - 竞争替代：通用 ChatGPT/Claude + 手工编排；专业编剧软件（Final Draft 等）无 AI 抽取
  - 可能收费方式：按项目订阅、按 token 转嫁

## 架构拆解

文字架构图：

```
[TXT 小说]
   │
   ▼
[ImportRail 前端] ──POST /api/extractions/preflight──► [chunking.analyze_novel_text]  (确定性，章节识别+分块)
   │                                                  │
   │ ──POST /api/extractions/jobs──► [ExtractionStateStore.create_or_restore_job]  (可恢复作业，本地 JSON)
   │                                                  │
   │ ──POST /api/extractions/jobs/{id}/chunks/next──► [NovelExtractionService.extract_chunk]
   │                                                       │
   │                                                       ▼
   │                                          [QiniuChatClient.complete]  (七牛云 LLM, JSON 模式)
   │                                                       │
   │                                                       ▼
   │                                          [ChunkExtraction.model_validate] + 修复重试 (MAX_REPAIR_ATTEMPTS=2)
   │                                                       │
   │                                                       ▼
   │                                          [ExtractionStateStore.mark_chunk_completed]  (持久化每 chunk 结果)
   │
   │ (全部 chunk 完成) ──► [_BibleMerger.merge]  (跨块合并人物/情节线/伏笔链接, 跨块伏笔自动配对)
   │                                  │
   │                                  ▼
   │                       [DocumentStore.write_bible]  (data/bible/*.yaml)
   │
[WorkbenchRail 故事画布] ◄──GET /api/story-map── [engine/projections + foreshadow_graph]  (确定性投影+依赖图)
   │
   │ (勾选待删 beat)
   │ ──POST /api/cut-impact──► [engine/cut_impact.analyze_cut_impact]  (纯代码, 不调 LLM)
   │                                  │
   │                                  ▼
   │                       人物高光丢失 / 伏笔悬空 / 情节线受损 / 级联影响
   │
   │ ──POST /api/projects──► [DocumentStore.write_project]  (保存 beat_decisions)
   │
[GenerationRail] ──POST /api/projects/{id}/scene-plan──► [engine/adaptation]  (确定性 scene plan)
   │ ──POST /api/projects/{id}/screenplay──► [llm/screenplay]  (LLM 逐场景生成+内心戏外化)
   │                                                  │
   │                                                  ▼
   │                                  [DocumentStore.write_screenplay] → screenplay.yaml (干净交付)
   │                                  [engine/reports] → reports.yaml (一致性/伏笔覆盖率)
```

关键请求追踪（砍戏影响，核心价值链）：
1. 前端 `useEffect`（`web/src/App.tsx:182`）监听 `cutBeatIds` 变化 → `fetchCutImpact(storyMap.bible_id, cutBeatIds)`
2. 后端 `/api/cut-impact`（`server/app/api/cut_impact.py`）→ `engine/cut_impact.py:75 analyze_cut_impact`
3. 该函数纯代码计算：`_character_highlight_impacts`（人物高光丢失）、`_foreshadow_impacts`（伏笔悬空）、`_thread_impacts`（情节线受损）、`build_foreshadow_graph` + `query_foreshadow_dependencies`（级联影响）
4. 返回 `CutImpactAnalysis`，前端 `ImpactRibbon` 实时展示 5 个指标

数据流/状态流/错误流：
- 数据流：TXT → chunks → ChunkExtraction（Pydantic 校验）→ BibleDocument → 投影/依赖图 → CutImpactAnalysis → ScenePlan → ScreenplayDocument
- 状态流：抽取作业有 `pending/running/completed/failed` 状态机（`server/app/store/extraction_jobs.py`），失败可从断点续抽
- 错误流：LLM 失败 → `LLMClientError` → 502；抽取输出校验失败 → 修复重试 → `ExtractionOutputError` → 502；chunking 失败 → 422
- 外部服务：仅七牛云 LLM API
- 数据库：无，全部本地 YAML/JSON 文件族
- 认证/权限/日志/监控：无（单机 MVP）

## 工程评分

| 维度 | 分数 | 证据 |
| --- | --- | --- |
| 产品完成度 | 4 | 完整闭环：导入→抽取→画布→砍戏预警→生成→导出。`docs/retrospective.md` 有真实数据验收。扣分：仅 TXT、单机、无 auth |
| 架构边界 | 5 | 三层（交互/引擎/状态）边界清晰；`engine/` 不调 LLM 是硬约束（README 第 137 行）；文档族生命周期分离设计优秀 |
| 可维护性 | 4 | Pydantic 为 Schema 真相源、shared JSON Schema 契约、frozen 模型、ruff/mypy/typecheck。扣分：`web/src/App.tsx` 单文件 1330 行，组件未拆分 |
| 可测试性 | 5 | 后端 95 个 pytest（事实），覆盖 engine/llm/api/store 全模块；前端 16 个测试；LLM 用 Protocol 抽象可注入 |
| 可观测性 | 2 | 无结构化日志、无 metrics、无 tracing；抽取作业有状态但无执行日志持久化 |
| 安全隐私 | 2 | 无 auth、无输入大小限制（text 字段无上限）、API key 明文读 .env、小说正文送第三方 LLM 无脱敏 |
| 性能并发 | 3 | chunk 串行调用 LLM（`extraction.py:197` 列表推导串行）；砍戏分析纯内存快；无并发控制 |
| 资源释放 | 3 | `QiniuChatClient` 用 `with httpx.Client()` 正确释放；但长文本抽取无超时熔断、无内存控制 |
| 成本控制 | 3 | chunk>50 时 warning（`chunking.py:208`）；但无 token 预估、无并发上限、无缓存去重（同正文重抽会再付费） |
| 部署恢复 | 3 | conda+npm workspaces 一键启动；可恢复抽取作业是亮点；但无容器化、无生产部署方案 |
| 文档和上手难度 | 5 | README/architecture.md/decisions.md/schema-design.md/retrospective.md/acceptance-checklist.md/optimization-log.md 文档极完整；上手路径清晰 |

问题分级：

- 阻断：无
- 重要：
  - 安全：无 auth、无输入大小上限、API key 管理简陋（`server/app/api/extractions.py:41` `text: str` 无 max_length）。触发条件：公网部署即风险。修复方向：加 auth 中间件 + 输入上限 + key 走 secret manager。
  - 性能：chunk 串行 LLM 调用，长小说耗时线性增长。修复方向：有限并发 + 异步任务队列。
  - 前端可维护性：`App.tsx` 1330 行单文件，状态管理散落 20+ useState。修复方向：拆分组件 + 引入状态管理。
- 一般：
  - git 历史被压缩为 1 commit，README 声称的开发过程无法验证（待验证假设）。
  - 无结构化日志与监控。
  - 本地文件存储无并发写保护。
- 建议：
  - 增加 EPUB/DOCX 解析。
  - scene plan 简化分组，后续做自动重排。
  - 抽取结果缓存去重，避免重复付费。

## 优点

1. 架构原则清晰且被严格执行：`engine/` 目录不调用 LLM（README 第 137 行明确声明，代码事实印证），使砍戏影响分析可复现、可单测。`server/app/engine/cut_impact.py` 全程纯代码。
2. Schema 作为产品契约的工程实践：Pydantic 模型（`server/app/models/documents.py`）为真相源，导出 `shared/contracts/*.schema.json`，前后端共享契约；最终 `screenplay.yaml` 严格只含剧本结构，不污染中间态（`docs/schema-design.md` 设计理由充分）。
3. 可恢复抽取作业：`ExtractionStateStore` 持久化每 chunk 结果，失败可断点续抽（`server/app/api/extractions.py:293` `extract_next_job_chunk`），对长文本 LLM 调用是必要的工程考量。
4. LLM 输出修复重试：`extraction.py:210` 校验失败后带具体校验问题重新请求 LLM 修复（`MAX_REPAIR_ATTEMPTS=2`），比直接报错更鲁棒。
5. 文档质量极高：`decisions.md`（22KB）记录技术取舍，`retrospective.md` 含真实验证证据与不足，`schema-design.md` 是议题正式交付物。
6. 测试覆盖扎实：95 后端 pytest + 16 前端测试，覆盖 engine/llm/api/store/schema 全链路。

## 缺点、风险与改进优先级

1. 安全（重要）：无认证、无输入大小限制、API key 明文 `.env`。公网部署即暴露风险。→ 加 auth + 输入上限 + secret 管理。
2. 性能（重要）：chunk 串行 LLM 调用，长小说耗时与成本线性增长；无并发、无熔断。→ 引入有限并发与异步队列。
3. 前端可维护性（重要）：`App.tsx` 1330 行单文件，20+ useState 散落，无状态管理库。→ 拆分组件 + zustand/reducer。
4. 可观测性（一般）：无结构化日志、无 metrics、无 tracing。→ 加 structlog + 基础 metrics。
5. 商业化未验证（一般）：单机本地存储、无多用户、无协作。→ 产品复用需补 DB 与 auth 层。
6. git 历史不可验证（一般）：README 声称 14 PR/47 commits，实际 1 commit。开发过程声明无法验证。
7. 输入格式单一（建议）：仅 TXT，无 EPUB/DOCX。

## 复用性矩阵

- 最值得保留的设计：
  - "LLM 当零件，确定性引擎守全局状态"的分层原则
  - beat 为外键的文档族数据模型（bible/project/screenplay/reports）
  - Pydantic 为 Schema 真相源 + shared JSON Schema 契约
  - 可恢复抽取作业状态机
  - 砍戏影响分析的纯函数实现（`engine/cut_impact.py`）
- 最需要警惕的问题：
  - 无 auth/无输入限制的安全 posture
  - 串行 LLM 调用的性能瓶颈
  - 单文件巨型组件的可维护性
- 可直接复用：`server/app/engine/`（确定性引擎，无外部依赖）、`server/app/models/documents.py`（Pydantic 文档模型）、`shared/contracts/*.schema.json`、`server/app/llm/chunking.py`（章节识别+分块）
- 改造后复用：`server/app/llm/client.py`（OpenAI 兼容客户端，需加重试/熔断/异步）、`server/app/store/`（需换 DB 后端）、抽取作业状态机（需换队列）
- 不应复用：前端 `App.tsx` 单文件结构、本地文件存储方案、无 auth 的 API 层

| 复用维度 | 分数 | 理由 |
| --- | --- | --- |
| 技术复用 | 4 | 引擎层、Schema 契约、chunking、砍戏分析均可直接复用；LLM 客户端与存储需改造 |
| 产品复用 | 3 | 产品闭环完整但单机；多用户/协作/DB 需重做；核心差异化（砍戏预警）可迁移 |
| 商业复用 | 2 | 无 auth/无计费/无多租户；商业化需补完整 SaaS 层；LLM 成本转嫁模式未验证 |

## 值得学习的内容

按学习收益排序：

1. 【进阶架构取舍】"LLM 当零件，确定性引擎守全局状态"——何时让 LLM 做局部语义、何时用纯代码守全局一致性。阅读 `server/app/engine/cut_impact.py` + `docs/retrospective.md` 第 3 节。
2. 【可迁移模式】以单一原子（beat id）为外键的文档族设计，让时间线/人物线/情节线/伏笔都从同一批 beats 派生，避免多视图各自落盘漂移。阅读 `server/app/models/documents.py` + `docs/schema-design.md`。
3. 【可复刻实验】LLM 输出校验失败后的定向修复重试（带具体校验问题重新 prompt）。阅读 `server/app/llm/extraction.py:273 build_extraction_repair_messages`。
4. 【可迁移模式】可恢复长任务状态机：每 chunk 结果持久化，失败断点续跑。阅读 `server/app/store/extraction_jobs.py` + `server/app/api/extractions.py:293`。
5. 【初学者概念】Pydantic 模型作为运行时校验 + JSON Schema 导出 + 前后端契约的单一真相源。阅读 `server/app/models/documents.py` + `shared/contracts/`。
6. 【可复刻实验】跨块伏笔自动配对：按 normalized tag 将 setup/payoff 跨 chunk 链接。阅读 `server/app/llm/extraction.py:480 _merge_cross_block_links`。
7. 【开放问题】如何让"砍戏影响"从 beat 级升级到场景级、主题级语义影响。

## 结构化 YAML 摘要

```yaml
project: PlotPulse
one_line_judgment: "工程素养明显高于同期演示项目的小说改剧本工作台，LLM 当零件+确定性引擎守全局状态是核心创新，单机 MVP 商业化未验证"
product_type: "AI 辅助小说改剧本工作台（结构化编辑器）"
target_users: ["独立编剧", "认真改编自己作品的小说作者"]
core_loop: "TXT 小说输入 -> LLM 分块抽取 beats/人物/伏笔 -> 确定性引擎投影与依赖图 -> 编剧取舍+砍戏影响可视化 -> LLM 场景生成 -> 干净 screenplay.yaml 导出"
architecture_style: "三层架构（交互层/引擎层/状态层），LLM 当零件、确定性代码守全局状态，文档族分离生命周期"
stack: ["React 19", "Vite 7", "TypeScript", "Python 3.12", "FastAPI", "Pydantic", "PyYAML", "Vitest", "pytest", "ruff", "mypy", "七牛云 LLM API (deepseek-v3)"]
strongest_patterns: ["LLM 当零件+确定性引擎守全局状态", "beat id 为外键的文档族数据模型", "Pydantic 为 Schema 真相源+shared JSON Schema 契约", "可恢复抽取作业状态机", "LLM 输出校验失败定向修复重试", "砍戏影响纯函数分析"]
main_risks: ["无 auth 与输入大小限制（公网部署即风险）", "chunk 串行 LLM 调用性能与成本线性增长", "前端 App.tsx 1330 行单文件可维护性差", "本地文件存储无并发写保护", "git 历史被压缩，开发过程声明无法验证", "小说正文送第三方 LLM 的版权隐私"]
business_scenarios: ["独立编剧小说改剧本", "小型影视改编团队结构化改编", "编剧教学与伏笔结构分析", "网文作者改编自己的作品为短剧"]
reusable_assets: ["server/app/engine/（确定性引擎，无外部依赖）", "server/app/models/documents.py（Pydantic 文档模型）", "shared/contracts/*.schema.json（JSON Schema 契约）", "server/app/llm/chunking.py（章节识别+分块）", "docs/schema-design.md + decisions.md（设计文档）"]
non_reusable_parts: ["web/src/App.tsx 单文件结构", "本地 YAML/JSON 文件存储", "无 auth 的 API 层", "conda+npm 单机部署方案"]
scores:
  product: 4
  architecture: 5
  engineering: 4
  reuse: 4
  commercialization: 2
evidence:
  - "server/app/engine/cut_impact.py:75 analyze_cut_impact（纯代码砍戏影响分析）"
  - "server/app/llm/extraction.py:191 NovelExtractionService（LLM 抽取编排）"
  - "server/app/llm/extraction.py:210 修复重试 MAX_REPAIR_ATTEMPTS=2"
  - "server/app/llm/extraction.py:480 _merge_cross_block_links（跨块伏笔配对）"
  - "server/app/llm/client.py:27 QiniuChatClient（七牛云 OpenAI 兼容客户端）"
  - "server/app/llm/chunking.py:53 analyze_novel_text（章节识别+分块）"
  - "server/app/models/documents.py:21 PlotPulseModel（frozen Pydantic 真相源）"
  - "server/app/store/documents.py DocumentStore（文档族存储）"
  - "server/app/api/extractions.py:293 extract_next_job_chunk（可恢复抽取）"
  - "web/src/App.tsx:182 砍戏影响 useEffect 实时计算"
  - "web/src/App.tsx:880 ImpactRibbon（影响预警展示）"
  - "docs/schema-design.md（议题交付物 Schema 设计）"
  - "docs/retrospective.md（真实验证证据与不足）"
  - "shared/contracts/*.schema.json（前后端契约）"
  - "git log 实际仅 1 commit vs README 声称 47 commits/14 PRs（待验证）"
  - "server/tests/ 95 个 pytest（事实）"
confidence: "高"
```
