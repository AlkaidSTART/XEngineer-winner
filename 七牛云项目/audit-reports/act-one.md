# Act One 审查报告

## 一句话判断

Act One 是一个 AI 小说转剧本 YAML 工作台，把 LLM 生成拆成可观测、可恢复、可降级的三阶段 Pipeline 并用 Schema 校验保障结构化输出，是五个项目里工程抽象最成熟、测试覆盖最扎实的一个，但前端工作台存在单文件巨型组件、SSE 并发与超时配置偏激进。

---

## 项目地图

- **根目录**：`/Users/allure/Desktop/七牛云项目/act-one`
- **语言/运行时**：后端 Java 17 + Spring Boot 3.5.7；前端 React 18 + TypeScript + Vite
- **三大子模块**：
  1. `backend` — Spring Boot 应用（端口 10001），Maven 构建，144 个 Java 文件，10125 行
  2. `frontend` — React + Vite 工作台（端口 5173），`App.tsx` 2322 行 + `workspace.tsx` 2121 行
  3. `sql/act-one.sql` + `docs/script-yaml-schema.md` — 数据库初始化与剧本 YAML Schema 文档
- **入口**：`ActOneApplication.java`（Spring Boot 主类）；`frontend/src/main.tsx`
- **数据层**：PostgreSQL + HikariCP + MyBatis-Plus，六张表（`t_user`/`t_script_project`/`t_script_chapter`/`t_script_conversion_task`/`t_script_draft`/`t_script_stage_result`），逻辑删除字段 `deleted`，雪花 ID
- **关键路径包边界**（README:205-209）：
  - `script.ai`（Pipeline 编排）→ `script` / `common`
  - `infra.ai`（Spring AI 客户端、模型路由）→ `ai` / `common` / Spring AI
  - `ai`（稳定端口 LLMService、消息模型、Prompt 接口）→ JDK only
  - 由 `BackendPackageBoundaryTest` 固定依赖方向
- **AI 资源**：Prompt 模板放 `backend/src/main/resources/prompt/v1/`（7 个 `.st` 模板），通过 `PromptTemplateService` 渲染
- **模型候选**：百炼（qwen3-max / qwen3.7-max / deepseek-v4-flash）+ SiliconFlow，优先级路由 + 健康熔断（`application.yml:67-97`）

---

## 产品与商业场景

- **目标用户**：小说作者、编剧、影视改编团队、AI 应用开发者（学习"模型编排+结构化生成+可追溯降级"链路）
- **场景痛点**：长篇小说改剧本早期阶段，章节拆解、场景规划、对白生成靠人工耗时且不可控；纯 LLM 一次生成质量不稳定且无法溯源
- **闭环**：
  - 输入：3 章以上小说文本（`NovelChapterParser` 识别章节+清洗+长章节分块）
  - 处理：三阶段 AI Pipeline（章节摘要 → 场景规划 → 剧本 YAML 生成）+ Schema 校验
  - 输出：结构化剧本 YAML 草稿（含幕/场景/对白/角色/来源章节/原文摘录）
  - 反馈：SSE 流式推送阶段进度 + 失败显式降级为规则版脚手架 + 作者局部精修/对白重写/节奏分析/分镜建议
- **独特价值**：
  1. 每个 scene 保留来源章节和原文摘录（SourceEvidence），作者可核对 AI 改编依据
  2. 三级降级（ai_pipeline → rule_based_fallback → rule_based_scaffold）确保任何故障下都有可用结果
  3. 阶段结果暂存 + `ScriptAiPipelineResumeState` 支持失败任务从安全阶段恢复
- **打动评委的瞬间**：SSE 进度条实时推进各阶段 + 降级原因明确展示 + 场景溯源点击跳转原文
- **商业化分析**：
  - 付费方：影视公司、编剧工作室（订阅/项目制）
  - 获客渠道：影视行业社区 + demo 视频 + 开源样板
  - 交付成本：中等（需 PostgreSQL + LLM API Key，服务器配置要求中等）
  - 持续使用理由：剧本改编是影视前期刚需，可迭代精修
  - 风险：LLM 成本（长文本多阶段调用）、生成质量天花板、版权合规

---

## 架构拆解

```
┌─ Frontend (React/Vite) ──────────────────┐
│ App.tsx 工作流编排（登录/导入/生成/编辑）  │
│ workspace.tsx 巨型组件库（14+ Workbench） │
│ scriptService.ts → /api/script/* REST+SSE │
│ scriptYamlTrace.ts YAML 溯源解析           │
└──────────────┬────────────────────────────┘
               │ REST + SSE
               ▼
┌─ Backend (Spring Boot) ──────────────────┐
│ controller/ (Auth/User/Novel/Project/    │
│   Draft/Demo)                             │
│ script.service/                            │
│   NovelChapterParser (章节识别+分块)       │
│   ScriptYamlGenerationService              │
│   ScriptYamlStreamService (SSE 编排)       │
│   ScriptYamlValidator (Schema 校验)        │
│   ScriptRhythmAnalysis/Storyboard/Refine   │
│ script.ai.pipeline/ (核心)                │
│   ScriptAiPipelineService (491行 编排)     │
│   LlmChapterSummaryStage (并发摘要)        │
│   LlmScenePlanningStage                    │
│   LlmScriptYamlGenerationStage (694行)     │
│   ScriptAiPipelineObserver (SSE 回调)      │
│   ScriptAiUsageTracker (token 计量)        │
│ ai/ (稳定端口)                             │
│   LLMService 接口                          │
│ infra.ai/ (基础设施)                       │
│   DefaultLLMService → ModelRoutingExecutor │
│   ModelSelector + ModelHealthStore         │
│   SpringAiChatClient → OpenAI 兼容         │
│   LLMResponseCleaner (清 markdown fence)   │
│ user/ (Sa-Token 认证)                      │
│ common/ (Result/异常/SseEmitterSender)     │
└──────────────┬────────────────────────────┘
               │
               ▼
        PostgreSQL + 百炼/SiliconFlow LLM
```

**关键调用链追踪（SSE 流式生成）**：
1. 前端 `streamGenerateScriptYaml`（`scriptService.ts`）→ `POST /api/script/drafts/yaml/from-text/stream`
2. `ScriptYamlStreamService.streamGenerateFromText`（`ScriptYamlStreamService.java:67`）创建 `SseEmitter`（10 分钟超时），`CompletableFuture.runAsync` 异步执行
3. 构建 `ScriptAiPipelineObserver` 将阶段事件（start/result/success/failure/fallback/complete）转 SSE payload 推送
4. `ScriptAiPipelineService.generate`（`ScriptAiPipelineService.java:109`）：
   - `chapterParser.parse` 识别章节（至少 3 章，否则抛 `ClientException`）
   - `summarizeChaptersConcurrently`（`:211`）用 `CompletableFuture` + `chapterSummaryExecutor` 并发摘要，`ScriptAiUsageTracker` 绑定 token 计量，`ScriptAiLlmCallTrace` 绑定调用链
   - `planScenes` 场景规划 → `generateYaml` YAML 生成
   - `validateOrFallback`（`:275`）：`ScriptYamlValidator.validate` 通过则 `success`，否则 `fallback` 走 `ruleBasedDraftService.generateFromText` + `markFallback` 改 generation_mode
5. 任何 `RuntimeException` / `ScriptAiPipelineStageException` 都被捕获并降级（`:148-172`），保证总有结果返回
6. `ModelRoutingExecutor.executeWithFallback`（`ModelRoutingExecutor.java:31`）按候选优先级遍历，`healthStore.allowCall` 检查熔断，失败 `markFailure` + 跳下一个

**状态流**：NovelChapter → ChapterSummary → ScenePlan → generatedYaml → ValidationResult → ScriptAiPipelineResult(generationMode/fallback/usage)
**错误流**：阶段异常 → `runStage` 重试（maxStageRetries=1）→ 仍失败抛 `ScriptAiPipelineStageException` → Pipeline 捕获 → `fallback` 生成规则版 + 标记 fallbackReason → SSE 推 `fallback` 事件
**可观测**：`log.info` 贯穿阶段开始/成功/失败/降级/完成，结构化字段（taskId/stage/model/retry/耗时/token）；`AiExceptionDiagnostics` 提取错误类型/错误码/根因

---

## 工程评分

| 维度 | 分数 | 证据 |
|------|------|------|
| 产品完成度 | 4.5 | 导入/生成/草稿/溯源/精修/节奏/分镜全链路落地，169 个后端测试 0 失败 |
| 架构边界 | 4.5 | 包边界清晰 + 测试固定依赖方向（README:211），稳定端口 `ai` 不绑 Spring AI |
| 可维护性 | 3.5 | 后端分层良好，但前端 `App.tsx` 2322 行 + `workspace.tsx` 2121 行巨型组件难维护 |
| 可测试性 | 4.5 | 34 个测试文件 169 个用例，含 Fake LLM 测试、包边界测试、Pipeline 降级测试 |
| 可观测性 | 4 | 阶段化结构化日志 + UsageTracker token 计量 + AiExceptionDiagnostics 根因诊断 |
| 安全隐私 | 3.5 | Sa-Token 认证 + 全局异常处理；但默认 admin/admin（README:231）、AI timeout 1000s 偏长 |
| 性能并发 | 3.5 | 章节摘要 CompletableFuture 并发 + 可配线程池；但 SSE 10 分钟超时 + AI 1000s timeout 易占用连接 |
| 资源释放 | 4 | `ScriptAiUsageTracker` try-with-resources、`UserContext.clear()` finally 清理、SseEmitter 完成回调 |
| 成本控制 | 3 | 长文本多阶段 LLM 调用成本高，UsageTracker 可计量但无配额限制；规则降级可省成本 |
| 部署恢复 | 3.5 | 标准 Spring Boot + Vite，需 PG + API Key；阶段结果暂存支持任务恢复 |
| 文档 | 4.5 | README 详尽含 Pipeline 图/降级策略/API 表/测试说明，另有 Schema 设计文档 |
| 上手难度 | 3.5 | 需 Java17+Maven+PG+Node，配置项多但文档完善 |

**问题分级**：
- **阻断**：无
- **重要**：
  - 前端 `App.tsx`（2322 行）和 `workspace.tsx`（2121 行）单文件巨型组件，状态管理与 UI 耦合，难维护难测试
  - AI `timeout: 1000s`（`application.yml:65`）单次调用最长 16 分钟，配合 SSE 10 分钟超时，高并发下连接易耗尽（README:12 自述"服务器配置很低，AI 并行调用可能导致崩溃"）
  - 默认管理员 admin/admin（README:231），生产环境未强制改密
- **一般**：
  - `chapter-summary` 阶段默认 `core-pool-size: 0`（`application.yml:103`），即用 `DIRECT_EXECUTOR` 同步执行（`ScriptAiPipelineService.java:33`），并发优势默认未启用
  - `ModelRoutingExecutor` 熔断 `open-duration-ms: 30000` + `failure-threshold: 2`（`application.yml:96`），30 秒恢复窗口偏短，可能频繁重试失败模型
  - SQL 初始化脚本 `DROP TABLE IF EXISTS`（`act-one.sql:22`）无幂等保护，重复执行丢数据
- **建议**：
  - 前端按工作台拆分独立组件 + 引入状态管理（Zustand/Redux）
  - AI 超时按阶段细化（已有 chapter-summary 480s / scene-planning 900s，但全局 1000s 冗余）
  - 增加用户级 LLM 配额限制

---

## 优点

1. **AI Pipeline 三阶段编排**（`ScriptAiPipelineService.java`）：章节摘要→场景规划→YAML 生成，每阶段独立可观测、可重试、可降级，是 LLM 结构化生成的成熟范式
2. **三级降级保障可用性**（`ScriptAiPipelineService.java:148-172`、`:314`）：ai_pipeline → rule_based_fallback → rule_based_scaffold，任何故障都有结果返回并明确告知降级原因
3. **阶段结果暂存 + 任务恢复**（`ScriptAiPipelineResumeState`、`ScriptConversionTaskService`）：失败任务可从安全阶段恢复，避免重新调用 LLM 浪费成本
4. **YAML Schema 校验防非法数据**（`ScriptYamlValidator.java`）：自定义 Schema 校验顶层/角色/幕/场景/来源，不合规触发降级，防止非法 YAML 静默进入草稿
5. **稳定端口 + 基础设施分层**（`ai` 包只依赖 JDK，`infra.ai` 绑 Spring AI）：业务逻辑不耦合具体模型客户端，可替换 LLM 实现
6. **模型路由 + 健康熔断**（`ModelRoutingExecutor` + `ModelHealthStore`）：多候选优先级路由，单模型失败自动跳下一个并标记熔断
7. **溯源追溯**（`SourceEvidence`、`scriptYamlTrace.ts`）：每个场景保留来源章节和原文摘录，作者可核对 AI 改编依据
8. **测试扎实**：169 个后端测试覆盖章节解析/Pipeline 成功失败降级/模型路由/包边界，含 Fake LLM 测试
9. **结构化日志 + token 计量**（`AiExceptionDiagnostics`、`ScriptAiUsageTracker`）：阶段化日志含 taskId/stage/model/retry/耗时/token，可观测性好
10. **全局异常处理完善**（`GlobalExceptionHandler.java`）：区分业务异常/远程异常/认证异常/校验异常/未知异常，统一 Result 包装

---

## 缺点风险与改进优先级

| 优先级 | 问题 | 影响 | 改进建议 |
|--------|------|------|----------|
| P0 | 前端 App.tsx + workspace.tsx 超 4400 行 | 难维护难测试，状态耦合 | 按工作台拆分 + 状态管理库 |
| P0 | AI timeout 1000s + SSE 10min | 高并发连接耗尽，自述服务器易崩 | 按阶段细化超时 + 连接池限流 |
| P1 | 默认 admin/admin | 生产环境安全风险 | 强制首次改密 + 随机初始密码 |
| P1 | 章节摘要并发默认未启用（core-pool 0） | 长文本摘要串行慢 | 默认启用合理并发度 |
| P2 | SQL 脚本 DROP TABLE 无幂等 | 重复执行丢数据 | 改 CREATE IF NOT EXISTS 或迁移工具 |
| P2 | 模型熔断 30s 恢复偏短 | 可能频繁重试失败模型 | 调长恢复窗口 + 指数退避 |
| P2 | 无用户级 LLM 配额 | 成本失控风险 | 增加配额计量与限制 |
| P3 | 长文本 LLM 成本高 | 商业化成本压力 | 缓存章节摘要 + 增量生成 |
| P3 | 前端无测试 | UI 回归无保障 | 补关键工作流测试 |

---

## 复用性矩阵

| 资产 | 复用性 | 说明 |
|------|--------|------|
| ScriptAiPipelineService 编排框架 | 可直接复用 | 通用 LLM 多阶段 Pipeline 编排，阶段化/可重试/可降级/可观测 |
| 三级降级策略 | 可直接复用 | ai_pipeline → rule_based_fallback → rule_based_scaffold 模式 |
| ModelRoutingExecutor + ModelHealthStore | 可直接复用 | 多模型候选路由 + 健康熔断，通用 LLM 基础设施 |
| ScriptYamlValidator Schema 校验 | 改造后复用 | 自定义 YAML Schema 校验思路通用，规则需按目标 Schema 改 |
| NovelChapterParser 章节解析 | 改造后复用 | 中文小说章节正则+长章节分块，可迁移到其他文本处理场景 |
| 稳定端口分层（ai/infra.ai） | 可直接复用 | 六边形架构思路，业务不绑具体模型客户端 |
| SSE Observer 模式 | 可直接复用 | Pipeline 事件 → SSE 推送的观察者模式 |
| ScriptAiUsageTracker token 计量 | 可直接复用 | try-with-resources + ThreadLocal 绑定的用量追踪 |
| 前端 workspace 巨型组件 | 不应复用 | 单文件过大，应拆分后再参考 |
| Prompt 模板（.st） | 改造后复用 | 模板组织方式可参考，内容需按业务改 |

**复用评分**：
- 技术复用：5（Pipeline 编排/降级/路由/校验/分层全套可迁移，是 LLM 应用的样板工程）
- 产品复用：3.5（小说转剧本闭环可迁移到其他文本结构化场景，如合同/报告/教案）
- 商业复用：3.5（影视前期刚需，但 LLM 成本与生成质量是天花板）

---

## 值得学习的内容

1. **（进阶）LLM 多阶段 Pipeline 编排**：`ScriptAiPipelineService` 把一次生成拆成可观测阶段，每阶段独立重试/降级/计量，是应对 LLM 不稳定的核心工程模式（`ScriptAiPipelineService.java:109-174`）
2. **（进阶）三级降级保障可用性**：ai_pipeline → rule_based_fallback → rule_based_scaffold，永远返回可用结果 + 明确降级原因，比单纯报错体验好得多（`:148-172`、`:314-345`）
3. **（进阶）稳定端口 + 基础设施分层**：`ai` 包只依赖 JDK 定义接口，`infra.ai` 绑 Spring AI 实现，业务逻辑可替换 LLM 供应商，是六边形架构实战（README:205-211）
4. **（进阶）模型路由 + 健康熔断**：多候选优先级 + 失败计数熔断 + 自动 fallback，比单模型调用健壮得多（`ModelRoutingExecutor.java:31-67`）
5. **（可迁移）Schema 校验防非法 LLM 输出**：LLM 生成的 YAML 必须过 `ScriptYamlValidator`，不合规触发降级，防止幻觉输出污染下游（`ScriptYamlValidator.java:24`）
6. **（可迁移）阶段结果暂存 + 任务恢复**：失败任务从安全阶段恢复，避免重复 LLM 调用，省成本（`ScriptAiPipelineResumeState`）
7. **（可迁移）SSE Observer 模式**：Pipeline 事件 → SSE 推送，前端实时感知阶段进度（`ScriptYamlStreamService.java`）
8. **（可复刻）结构化日志 + token 计量**：阶段化日志含 taskId/stage/耗时/token，`AiExceptionDiagnostics` 提取根因，是 LLM 应用可观测性标配
9. **（初阶）包边界测试**：用测试固定模块依赖方向，防止业务逻辑反向依赖基础设施（`BackendPackageBoundaryTest`）
10. **（反面教材）前端巨型组件**：workspace.tsx 2121 行是反例，提醒拆分组件与状态管理

---

## 结构化 YAML 摘要

```yaml
project: act-one
one_line_judgment: "AI 小说转剧本 YAML 工作台，三阶段 Pipeline + 三级降级 + Schema 校验，工程抽象最成熟但前端巨型组件待拆"
product_type: "AI 辅助内容结构化工具（小说转剧本）"
target_users: ["小说作者", "编剧", "影视改编团队", "AI 应用开发者"]
core_loop: "小说文本输入 → 章节解析 → 三阶段 AI Pipeline（摘要/场景/YAML） → Schema 校验 → 草稿+溯源 → 精修/分析/分镜"
architecture_style: "后端六边形分层（ai 稳定端口 + infra.ai 基础设施 + script.ai 业务 Pipeline），前端单页工作台"
stack: ["Java 17", "Spring Boot 3.5.7", "MyBatis-Plus", "PostgreSQL", "HikariCP", "Sa-Token", "Spring AI", "React 18", "TypeScript", "Vite", "SnakeYAML"]
strongest_patterns: ["三阶段 AI Pipeline 编排（摘要/场景/YAML）", "三级降级（ai_pipeline/rule_based_fallback/rule_based_scaffold）", "稳定端口 + 基础设施分层（ai/infra.ai）", "模型路由 + 健康熔断（ModelRoutingExecutor）", "YAML Schema 校验防非法输出", "阶段结果暂存 + 任务恢复", "SSE Observer 事件推送", "结构化日志 + token 计量", "包边界测试固定依赖方向"]
main_risks: ["前端 App.tsx+workspace.tsx 超 4400 行巨型组件", "AI timeout 1000s + SSE 10min 连接耗尽风险", "默认 admin/admin 安全风险", "长文本多阶段 LLM 成本高", "章节摘要并发默认未启用", "SQL 脚本 DROP TABLE 无幂等"]
business_scenarios: ["小说改编剧本初稿", "长文本结构化拆解", "AI 应用 Pipeline 工程样板", "影视前期内容工作流"]
reusable_assets: ["ScriptAiPipelineService 编排框架", "三级降级策略", "ModelRoutingExecutor + ModelHealthStore", "稳定端口分层架构", "ScriptYamlValidator Schema 校验", "NovelChapterParser 章节解析", "SSE Observer 模式", "ScriptAiUsageTracker token 计量", "AiExceptionDiagnostics 根因诊断"]
non_reusable_parts: ["前端 workspace 巨型组件", "具体 Prompt 模板内容", "PostgreSQL 建表 SQL", "影视剧本特定业务模型"]
scores:
  product: 4.5
  architecture: 4.5
  engineering: 4
  reuse: 5
  commercialization: 3.5
evidence:
  - "backend/src/main/java/com/hjan/actone/script/ai/pipeline/ScriptAiPipelineService.java:109-174 (Pipeline 编排+降级)"
  - "backend/src/main/java/com/hjan/actone/script/ai/pipeline/ScriptAiPipelineService.java:314-345 (fallback 规则版)"
  - "backend/src/main/java/com/hjan/actone/infra/ai/model/ModelRoutingExecutor.java:31-67 (模型路由+熔断)"
  - "backend/src/main/java/com/hjan/actone/script/service/ScriptYamlValidator.java:24-94 (Schema 校验)"
  - "backend/src/main/java/com/hjan/actone/script/service/NovelChapterParser.java:18-100 (章节解析+分块)"
  - "backend/src/main/java/com/hjan/actone/script/service/ScriptYamlStreamService.java:67-119 (SSE 编排)"
  - "backend/src/main/resources/application.yml:65 (AI timeout 1000s)"
  - "backend/src/main/resources/application.yml:103 (chapter-summary core-pool 0)"
  - "frontend/src/App.tsx (2322 行巨型组件)"
  - "frontend/src/components/workspace.tsx (2121 行巨型组件)"
  - "backend/src/test (34 测试文件 169 用例)"
  - "README.md:231 (默认 admin/admin)"
confidence: "高"
```
