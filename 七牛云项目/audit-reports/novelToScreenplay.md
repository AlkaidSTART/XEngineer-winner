# novelToScreenplay 项目审查报告

## 一句话判断

一个功能覆盖完整的小说影视化改编工作台原型：从小说导入、章节叙事分析、角色/关系/时间线抽取，到场景拆分、剧本生成、分镜生图、视频任务管理的全链路均已实现，领域模型丰富、原文溯源设计亮眼，但前后端均无认证、数据全靠本地文件缓存、测试仅覆盖单服务，是典型的功能原型而非生产系统。

## 项目地图

- **项目根目录**: `/Users/allure/Desktop/七牛云项目/novelToScreenplay`
- **项目名称**: 小说转剧本创作工作台（novel-to-screenplay）
- **语言与框架**: 后端 Python / FastAPI + Pydantic；前端 React 18 + TypeScript + Vite 6 + React Router + AntV G6 + dnd-kit + GSAP（事实，依据 `requirements.txt`、`package.json`）
- **运行入口**: 后端 `uvicorn app.main:app`（`apps/api/app/main.py`）；前端 `npm run web:dev` -> `vite`（`apps/web/package.json`）
- **主要可执行路径**:
  - 后端入口: `apps/api/app/main.py` -> `app/api/routes.py`（505 行，30+ 路由）
  - 核心服务: `apps/api/app/services/chapter_analysis_service.py`（901 行）、`model_gateway.py`、`seedance_client.py`、`seedream_image_client.py`
  - 前端入口: `apps/web/src/main.tsx` -> `router.tsx` -> 13 个 feature 页面
- **边界识别**:
  - 前端: React SPA，13 个 feature 页面（import/characters/relationships/timeline/scenes/screenplay/video/settings）
  - 后端: FastAPI monolith，按 services 分层（document_parser/chapter_analysis/model_gateway/seedance/seedream/screenplay/storyboard_prompt/workspace/settings）
  - 外部服务: DeepSeek（叙事分析/剧本补全/分镜提示词）、Seedream（分镜生图）、Seedance（视频生成）、火山方舟 Ark（模型列表）
  - 数据: 无数据库，全靠本地文件缓存（`.cache/deepseek/` JSON 缓存 + `.debug/deepseek/` 调试文件 + `.data/generated_media/` 媒体产物）
  - 异步: FastAPI BackgroundTasks 用于章节分析后台执行
- **目录结构**（关键文件）:
  ```
  apps/api/app/
    main.py / api/routes.py (30+路由)
    domain/models.py (325行，20+领域模型)
    services/
      chapter_analysis_service.py (901行，核心)
      model_gateway.py (统一模型网关)
      screenplay_generation_service.py
      seedance_client.py / seedream_image_client.py
      storyboard_prompt_service.py
      workspace_service.py (用例编排)
    application/container.py (DI装配) / ports.py (端口接口)
    config/ (4个prompt markdown模板)
    core/ (config/persistence/logging/storage)
  apps/web/src/
    features/ (13个页面组件)
    shared/ (api.ts 1388行, types.ts 468行, currentNovel.ts等)
  docs/ (10+架构/实现规划文档)
  schemas/ (screenplay YAML schema)
  ```

## 产品与商业场景

### 目标用户与痛点

- **目标用户**: 影视改编前期开发人员、编剧、制片人（合理推断，产品定位为"影视改编前期开发"）
- **场景痛点**: 长篇小说改编为剧本需要大量人工阅读、角色梳理、场景拆分工作；现有工具不提供从小说到分镜视频的一站式工作流
- **输入/处理/输出/反馈闭环**:
  - 输入: 上传 TXT/MD/Docx 小说文件 -> 自动解析章节
  - 处理: 逐章 LLM 叙事分析（角色/事件/关系/冲突/对话/环境/分镜规划）-> 聚合合并 -> 层级场景拆分
  - 输出: 角色卡片/关系图/时间线/场景板/剧本（可 AI 补全）/分镜图片/视频任务
  - 反馈: 原文溯源（source_refs + start_char/end_char 定位），可在页面点击比对原文
- **独特价值**: 全链路一站式（小说 -> 叙事分析 -> 剧本 -> 分镜图 -> 视频），且每个环节保留原文溯源
- **打动评委的体验瞬间**: 上传小说 -> 自动抽取角色和关系图（G6 可视化）-> 场景拆分 -> AI 补全剧本 -> 生成分镜图 -> 生成视频，全流程可演示

### 商业化分析

- **付费方**: 影视制作公司/工作室（B 端）或独立编剧（C 端）（合理推断）
- **使用者**: 编剧、改编策划、分镜师
- **决策者**: 制片人/制作总监
- **获客渠道**: 影视行业展会、编剧社区、制作公司 BD
- **交付成本**: DeepSeek 按章/token 计费（长篇小说章节多，成本显著）；Seedream 生图 + Seedance 视频按次计费
- **持续使用理由**: 改编工作流工具化，减少人工阅读和梳理时间
- **数据/模型成本**: 每章 1 次 LLM 分析（有 hash 缓存）；图片和视频生成成本较高
- **合规/隐私**: 小说文本可能涉及版权；上传内容存本地；无多用户隔离
- **竞争替代品**: 人工编剧 + Final Draft/Celtx；无直接竞品做全链路
- **可能收费方式**: B 端按项目/席位授权；C 端订阅 + 按量计费图片/视频

## 架构拆解

### 文字架构图

```
[浏览器 React SPA]
  ├── 导入页 (上传小说 -> POST /api/documents/import)
  ├── 角色/关系/时间线页 (GET /api/characters, /api/relationships, /api/events)
  ├── 场景页 (GET /api/scenes)
  ├── 剧本页 (POST /api/screenplays/complete-scene AI补全 + 本地草稿)
  ├── 分镜生图页 (POST /api/storyboard-prompts/* + POST /api/images/seedream/generations)
  ├── 视频生成页 (POST /api/videos/seedance/tasks)
  └── 设置页 (POST /api/settings/deepseek, /api/settings/seedance)

[FastAPI 后端]
  ├── routes.py (30+ REST 路由)
  ├── WorkspaceService (用例编排, 依赖注入 ports)
  ├── ChapterAnalysisService (逐章并发分析 + hash缓存 + 聚合合并)
  ├── ModelGateway (统一OpenAI兼容接口, 多provider)
  ├── SeedanceClient / SeedreamImageClient (视频/图片生成)
  └── BackgroundTasks (异步分析)

[本地文件系统]
  ├── .cache/deepseek/ (章节分析JSON缓存, 按hash命名)
  ├── .debug/deepseek/ (请求/响应/错误调试文件)
  └── .data/generated_media/ (图片/视频产物)
```

### 一条完整请求追踪

以"叙事分析"为例（`routes.py:191`、`workspace_service.py`、`chapter_analysis_service.py:91`）：

1. `POST /api/documents/{id}/analysis` -> `workspace_service.start_analysis()` 返回 `AnalysisStartResult`
2. `BackgroundTasks.add_task(workspace_service.run_analysis, ...)` 后台执行
3. `analyze_chapters()` 对每章并发执行 `_analyze_single_chapter()`，受 `asyncio.Semaphore` 限制并发数（`chapter_analysis_service.py:99`）
4. 每章：检查 hash 缓存 -> 命中则读缓存 -> 未命中则 `_build_user_prompt()` -> `deepseek_client.extract_json()` -> 写缓存 + 调试文件
5. `aggregate_chapter_analyses()` 聚合：合并角色（按 name 去重+合并 aliases/costumes/source_refs）、收集各类结构化信息、附加 ID 关联、层级场景数据补全
6. `_attach_source_positions()` 将 source_refs 的 evidence 文本在章节正文中定位 start_char/end_char
7. 前端轮询 `GET /api/documents/{id}/analysis` 获取状态和结果

### 模块调用方向

- 前端 -> 后端 REST API -> WorkspaceService（编排）-> 各 Service -> ModelGateway/SeedanceClient/SeedreamImageClient -> 外部 API
- WorkspaceService 通过 `application/ports.py` 定义端口接口，`application/container.py` 装配具体实现（依赖注入）
- ChapterAnalysisService 解析 LLM JSON 返回为 20+ 领域模型（`domain/models.py`），再做跨章聚合

### 数据流/状态流/错误流

- **数据流**: 文件上传 -> 解析章节 -> 逐章 LLM 分析 -> 聚合 -> 本地文件缓存 -> 前端展示
- **状态流**: 分析状态 `idle -> running -> completed/failed`，支持 retry（`routes.py:208`）
- **错误流**: 章节分析失败跳过该章返回空分析（`chapter_analysis_service.py:218-220`）；LLM 配置缺失返回 400；外部 API 失败返回 502；调试文件记录请求/响应/错误
- **缓存流**: 章节内容 hash 作为缓存 key -> 内容不变跳过 LLM 请求 -> 缓存 schema 版本控制（`_cache_payload`/`_unwrap_cache_payload`）

## 工程评分

| 维度 | 分数 | 证据 |
|------|------|------|
| 产品完成度 | 5 | 全链路功能均已实现：导入/分析/角色/关系/时间线/场景/剧本/分镜图/视频；13 个前端页面；30+ API 路由 |
| 架构边界 | 4 | 后端有 ports 接口 + DI 装配（`application/ports.py`、`container.py`）；ModelGateway 统一多 provider；但前后端类型未共享（README 提及"共享类型契约"但 packages 目录未见实现） |
| 可维护性 | 3 | 领域模型丰富但 chapter_analysis_service.py 901 行单文件偏大；routes.py 505 行 30+ 路由单文件；前端 api.ts 1388 行 |
| 可测试性 | 2 | 仅 1 个测试文件 `test_workspace_service.py`（111 行）；无前端测试；无集成测试；有 DI 但测试覆盖极低 |
| 可观测性 | 3 | 后端有结构化中文日志（`logging_config.py`）；调试文件保存请求/响应/错误；但无 metrics/tracing |
| 安全隐私 | 2 | 无认证授权；API Key 可从前端保存到后端 .env（`settings_service.py`）；CORS allow_credentials=True + allow_methods=["*"]；无输入长度限制 |
| 性能并发 | 3 | 章节分析有 Semaphore 并发控制 + hash 缓存；但全靠本地文件 I/O；无数据库；长篇小说分析耗时 |
| 资源释放 | 3 | httpx 使用 async with；但 BackgroundTasks 无超时/取消机制；文件句柄管理靠 Python GC |
| 成本控制 | 3 | 章节分析 hash 缓存避免重复请求；但无用量配额/告警；图片视频生成无限制 |
| 部署恢复 | 2 | 无 Dockerfile/CI；数据全靠本地文件，无备份；无数据库 |
| 文档 | 5 | 10+ 架构/实现规划文档；README 极详尽；AGENTS.md 协作约束；中文日志注释规范 |
| 上手难度 | 3（中等偏难） | 需配置 3 个 API Key；需 Python+Node 双环境；理解 20+ 领域模型 |

### 问题分级

**重要**:
- 无认证授权系统，所有 API 裸露（`routes.py` 全部无 auth）
- 无数据库，全靠本地文件缓存，数据持久性和并发性无保障
- 测试覆盖极低（仅 1 个测试文件），核心分析逻辑无测试保护
- API Key 可从前端直接写入后端 .env 文件，安全风险高（`settings_service.py`）

**一般**:
- chapter_analysis_service.py 901 行单文件，解析/聚合/溯源逻辑混杂
- 前后端类型未真正共享（README 提及但 packages 目录空）
- 无 Docker/CI
- BackgroundTasks 无超时/取消机制，长篇小说分析可能卡死

**建议**:
- CORS 生产环境应收紧
- 添加输入文件大小限制
- ModelGateway 添加重试和熔断

## 优点

1. **全链路一站式工作流**: 从小说导入到视频生成的完整链路均有实现，不是 demo 级别的半成品，每个环节都有可交互的页面和 API（13 页面 + 30+ 路由）
2. **原文溯源设计**: 每个抽取的结构化信息都带 `source_refs`（chapter_id + evidence + start_char/end_char），可在页面点击比对原文，解决 LLM 抽取结果与原文脱节的问题（`chapter_analysis_service.py:714-779`）
3. **章节分析 hash 缓存**: 按章节内容 hash 缓存分析结果，内容不变跳过 LLM 请求，节省成本；缓存有 schema 版本控制（`chapter_analysis_service.py:166-191`）
4. **领域模型丰富**: 20+ 领域模型（Character/Event/Relationship/Conflict/Dialogue/Action/Motivation/CausalLink/Scene/SubScene/NarrativeBlock/ShotPlan/EnvironmentInfo/TimeMarker/EmotionArc 等），覆盖叙事分析的各个方面（`domain/models.py`）
5. **跨章聚合合并**: 角色按 name 去重合并 aliases/costumes/source_refs/importance；各类信息跨章收集并重新分配 ID（`chapter_analysis_service.py:42-88`、`563-640`）
6. **ModelGateway 统一多 provider**: 统一 OpenAI 兼容接口，支持多模型供应商档案配置和切换（`model_gateway.py`）
7. **调试文件完善**: 每次模型请求保存 request/response/error/content 到调试目录，便于排查提示词问题（`model_gateway.py:76-128`）
8. **文档质量极高**: 10+ 架构/实现规划文档，README 详尽，有协作约束和中文日志注释规范

## 缺点、风险与改进优先级

| 优先级 | 问题 | 影响 | 证据位置 | 修复方向 |
|--------|------|------|----------|----------|
| P0 | 无认证授权 | 任意人可操作 | `routes.py` 无 auth | 加 auth 中间件 |
| P0 | 无数据库全靠文件 | 数据持久性/并发性无保障 | `.cache/` + `.debug/` + `.data/` | 引入数据库 |
| P0 | 测试覆盖极低 | 核心逻辑无保护 | 仅 `test_workspace_service.py` | 补充 chapter_analysis/model_gateway 测试 |
| P0 | API Key 前端写入后端 .env | 安全风险 | `settings_service.py` | 改用环境变量/密钥管理服务 |
| P1 | 无 Docker/CI | 部署不可复现 | 目录无 Dockerfile | 加 Dockerfile + CI |
| P1 | chapter_analysis_service.py 过大 | 维护困难 | 901 行单文件 | 拆分解析/聚合/溯源 |
| P1 | 前后端类型未共享 | 类型不一致风险 | `packages/` 目录空 | 实现 shared types 包 |
| P2 | BackgroundTasks 无超时 | 长分析可能卡死 | `routes.py:201` | 加超时/取消 |
| P2 | api.ts 1388 行 | 前端维护困难 | `apps/web/src/shared/api.ts` | 按 feature 拆分 |

## 复用性矩阵

### 最值得保留的设计

1. **原文溯源机制**（source_refs + start_char/end_char + evidence 定位）: 任何需要 LLM 抽取结构化信息并溯源到原文的场景都可直接复用
2. **章节分析 hash 缓存 + schema 版本控制**: 任何按内容 hash 缓存 LLM 结果的场景可复用
3. **领域模型设计**（20+ 叙事分析模型）: 影视改编/叙事分析领域的参考模型
4. **ModelGateway 统一多 provider 网关**: 统一 OpenAI 兼容接口 + 多档案配置 + 调试文件
5. **跨章聚合合并模式**: 角色去重合并、ID 重新分配、层级场景数据补全

### 最需要警惕的问题

1. 无数据库全靠文件缓存的架构不可用于生产
2. API Key 从前端写入后端 .env 的做法有安全隐患
3. 测试覆盖极低，重构风险高

### 复用性评分

| 维度 | 分数 | 理由 |
|------|------|------|
| 技术复用 | 4 | 原文溯源、hash缓存、ModelGateway、领域模型、跨章聚合均可独立复用；但代码耦合度较高 |
| 产品复用 | 5 | 全链路工作流可直接作为影视改编产品基础；场景扩展空间大 |
| 商业复用 | 3 | 产品价值清晰但缺认证/数据库/测试基建；API 成本高；需大量补全 |

### 可直接复用 / 改造后复用 / 不应复用

- **可直接复用**: `domain/models.py`（领域模型）、原文溯源逻辑（`_locate_refs`/`_attach_source_positions`）、hash 缓存模式、ModelGateway 调试文件机制
- **改造后复用**: `chapter_analysis_service.py`（拆分后可复用）、`model_gateway.py`（加重试/熔断后可复用）、前端 feature 页面布局模式
- **不应复用**: 文件缓存作为数据层、API Key 写入 .env 的 settings_service、无 auth 的路由层

## 值得学习的内容

1. **（进阶）LLM 抽取结果的原文溯源设计**: 每个抽取项带 source_refs（chapter_id + evidence + start_char/end_char），解析后在章节正文中用 find 定位字符位置，前端可点击跳转原文。这种"AI 抽取 + 人类可验证"模式适用于任何需要信任校验的 AI 抽取场景。阅读路径: `chapter_analysis_service.py:714-779` -> `domain/models.py` SourceRef
2. **（进阶）按内容 hash 缓存 LLM 结果 + schema 版本控制**: 章节内容不变时跳过 LLM 请求；缓存有 `_cache_schema_version` 字段，版本不匹配时忽略旧缓存。阅读路径: `chapter_analysis_service.py:166-191`、`825-835`
3. **（进阶）跨章聚合合并模式**: 多章分析结果按角色 name 去重，合并 aliases/costumes/source_refs/importance；各类信息收集后重新分配 ID 并建立关联（event->character_ids, scene->event_ids, sub_scene->dialogue_ids）。阅读路径: `chapter_analysis_service.py:42-88`、`563-640`
4. **（初学者）FastAPI + ports + DI 架构**: ports.py 定义抽象接口，container.py 装配具体实现，WorkspaceService 通过构造函数注入依赖。阅读路径: `application/ports.py` -> `application/container.py` -> `services/workspace_service.py`
5. **（可复刻实验）ModelGateway 统一多 provider + 调试文件**: 统一 OpenAI 兼容接口调用不同 provider，每次请求保存 request/response/error/content 调试文件。阅读路径: `model_gateway.py` 全文
6. **（可迁移模式）层级场景数据补全**: 当 LLM 未返回 narrative_blocks 或 sub_scenes 时，用 fallback 从 chapter/scene 生成，保证数据结构完整。阅读路径: `chapter_analysis_service.py:610-679`

## 结构化 YAML 摘要

```yaml
project: novelToScreenplay
one_line_judgment: "功能覆盖完整的小说影视化改编工作台原型，全链路从小说到视频均可交互，原文溯源设计亮眼，但无认证/无数据库/测试极低是典型功能原型"
product_type: "小说转剧本影视化改编工作台"
target_users: ["影视改编前期开发人员", "编剧", "制片人", "分镜师"]
core_loop: "上传小说 -> 自动解析章节 -> 逐章LLM叙事分析(角色/事件/关系/冲突/对话/环境/分镜) -> 跨章聚合合并 -> 场景拆分 -> AI剧本补全 -> 分镜生图(Seedream) -> 视频生成(Seedance) -> 原文溯源校验"
architecture_style: "FastAPI monolith + ports/DI分层 + 本地文件缓存(无数据库) + 多外部AI服务编排(DeepSeek/Seedream/Seedance)"
stack: ["Python", "FastAPI", "Pydantic", "httpx", "React 18", "TypeScript", "Vite", "React Router", "AntV G6", "dnd-kit", "GSAP", "ECharts", "DeepSeek", "Seedream", "Seedance", "火山方舟Ark"]
strongest_patterns: ["LLM抽取结果原文溯源(source_refs+char定位)", "章节内容hash缓存+schema版本控制", "跨章聚合合并(角色去重/ID重分配/层级补全)", "ModelGateway统一多provider+调试文件", "20+领域模型覆盖叙事分析", "FastAPI BackgroundTasks异步分析"]
main_risks: ["无认证授权", "无数据库全靠本地文件缓存", "测试覆盖极低(仅1个测试文件)", "API Key前端写入后端.env", "无Docker/CI", "chapter_analysis_service.py 901行过大"]
business_scenarios: ["B端影视制作公司改编工作流", "C端独立编剧辅助工具", "影视教学演示", "IP改编前期评估"]
reusable_assets: ["domain/models.py 领域模型", "chapter_analysis_service.py 原文溯源逻辑", "hash缓存+schema版本控制模式", "ModelGateway统一网关+调试文件", "跨章聚合合并模式", "4个prompt模板markdown"]
non_reusable_parts: ["文件缓存作为数据层", "API Key写入.env的settings_service", "无auth的路由层", "901行单文件chapter_analysis_service"]
scores:
  product: 5
  architecture: 4
  engineering: 2
  reuse: 4
  commercialization: 3
evidence: ["apps/api/app/api/routes.py:191-218 (分析启动+retry)", "apps/api/app/services/chapter_analysis_service.py:91-120 (并发分析)", "apps/api/app/services/chapter_analysis_service.py:166-191 (hash缓存)", "apps/api/app/services/chapter_analysis_service.py:714-779 (原文溯源)", "apps/api/app/services/chapter_analysis_service.py:42-88 (跨章聚合)", "apps/api/app/services/model_gateway.py:63-128 (统一网关)", "apps/api/app/domain/models.py (20+领域模型)", "apps/api/app/application/ports.py (端口接口)", "apps/api/tests/test_workspace_service.py (唯一测试)"]
confidence: "高"
```
