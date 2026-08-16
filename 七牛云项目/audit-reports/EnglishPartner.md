# EnglishPartner (英客 EToker) 项目审查报告

## 一句话判断

一款产品完成度极高的 AI 英语口语陪练工具，采用 Go 后端 + React 前端 + Provider 可替换架构，覆盖从"开口说"到"复盘再练"的完整学习闭环，无 API Key 时仍可用规则教练兜底，是本批项目中产品设计最系统化的项目之一。

## 项目边界

- 仓库路径：`/Users/allure/Desktop/七牛云项目/EnglishPartner`
- Git 状态：仅 1 个 commit（`be16fad Merge pull request #15 from HuangBo6497/Annotation-Supplement15`），README 与 commit 信息显示历史被压缩/重写，开发过程不可完整追溯（事实，`git log --all --oneline` 仅 1 行）。
- 产品定位：比赛和产品验证阶段 MVP，本地可直接启动（事实，README.md:5）。
- 代码规模：Go 后端 8960 行（39 个 .go 文件），前端 TS/TSX 8700 行（26 个文件），60 个场景 JSON（事实，`wc -l` + `find` 统计）。
- Monorepo 结构：`apps/web`（React 前端）、`apps/server`（Go 后端）、`packages/shared`（TypeScript 共享契约）、`data/scenarios`（场景配置）、`docs`（架构/API 文档）（事实，目录树）。
- 后端依赖仅 2 个直接依赖：`github.com/coder/websocket v1.8.14`、`modernc.org/sqlite v1.34.5`，无 Web 框架、无 ORM（事实，go.mod）。

## 用户与产品闭环

### 目标用户
中国英语学习者，需在面试、考试（CET/IELTS/TOEFL/考研复试）、职场、留学、旅游、兴趣交流等真实场景中练习多轮英语对话（事实，README.md:3）。

### 产品闭环（7 步，README.md:28-36）
1. 用户设置学习目标和当前水平
2. 系统推荐今日任务（`learningPlan.ts` 中 `goalScenarioIDs` 按 6 类目标映射场景，事实）
3. 用户进入具体场景用英语和 AI 角色对话
4. 练习中可请求提示（hint）、简化表达（simplify）、中文思路（idea）、重说本轮
5. 结束后生成结构化报告（综合分、等级、雷达图、优势、缺陷、典型错误、训练计划）
6. 报告中的错误和好表达沉淀到学习库（错题库、表达库）
7. 成长页聚合历史练习为趋势和常错点

### 关键差异化设计
- "不是聊天机器人，而是口语训练产品"：不把"能聊天"作为终点，围绕口语学习真实行为设计闭环（事实，README.md:27-28）。
- "语音优先，但保留可解释状态"：练习房间显式展示连接状态、麦克风状态、字幕、AI 回复状态、报告生成进度和 fallback 原因（事实，README.md:38-40）。
- "Provider 可替换，避免绑定单一厂商"（事实，README.md:42-53）。

## 技术架构

### 架构风格
Provider 可替换的分层单体，本地优先（local-first）。后端通过接口抽象教练、语音、发音评测、翻译、存储五类能力，每类都有默认兜底实现，API 层只依赖接口不绑定具体厂商（事实，`api/server.go:43-50` Dependencies struct 全部是接口）。

### 核心架构图（事实，README.md:120-149 + docs/architecture.md）
```
React Web App
  ├── HTTP JSON → Go HTTP API → Scenario Repository / Session Store / Coach Provider / Speech Provider / Translation Provider
  ├── WebSocket → Realtime Hub (in-memory pub/sub) → Coach → Store
  └── WebSocket + PCM Audio → Local Voice WS Proxy → Qwen Omni Realtime Provider → DashScope
```

### Provider 可替换体系（本项目最突出的架构模式）

| 能力 | 接口 | 默认/兜底实现 | 可选实现 | 装配点 |
|------|------|--------------|---------|--------|
| 教练 | `coach.Provider`（Respond/Summarize） | `RuleBasedCoach`（无密钥可运行） | `OpenAICompatibleCoach`（带 rule fallback） | `main.go:70-97` `buildCoachProvider` |
| 语音 | `voice.Provider`（Connect/IsConfigured） | `DisabledProvider`（返回 ErrNotConfigured） | `QwenOmniRealtimeProvider` | `main.go:110-137` `buildVoiceProvider` |
| 发音 | `speech.Provider`（AssessPronunciation） | `BrowserAssessmentProvider`（浏览器证据评估） | - | `main.go:99-108` |
| 翻译 | （内联在 API 层） | `quick-local`（本地快速翻译） | `tencent-tmt`（腾讯云 TMT） | `translation.go:38-63` `translateText` |
| 存储 | `api.SessionStore` | `SQLiteSessionStore` | `SessionStore`（JSON） | `main.go:46-68` `buildSessionStore` |
| 实时 | `realtime.Hub`（Publish/Subscribe） | `MemoryHub`（进程内 pub/sub） | - | `api/server.go:58-60` |

关键事实：每个 Provider 在 `main.go` 装配时都有 fallback 逻辑——LLM 教练构造失败返回 rule 教练（`main.go:90-93`），语音 Provider 构造失败返回 DisabledProvider（`main.go:130-133`），未知 Provider 名一律降级到兜底实现。`OpenAICompatibleCoach` 内部还持有 `fallback Provider`，LLM 调用失败或返回空内容时自动降级到 rule 教练（`openai_compatible.go:190-195`、`211-216`）。

### 核心链路

#### 1. 创建场景并进入练习（事实，README.md:202-219）
`POST /api/sessions` → `ScenarioRepository.Get` → 创建 `PracticeSession` → 保存到 SQLite → 前端跳转 `/practice/:sessionId`。

#### 2. WebSocket 文本实时对话（事实，`api/realtime.go` + `realtime/hub.go`）
- 前端建立 `/api/sessions/{id}/realtime` WebSocket 连接
- 服务端立即推送 `session.snapshot`
- 前端发 `turn.submit`，服务端依次推送 `turn.processing` → `turn.user_echo` → `turn.thinking`（流式思考） → `turn.delta`（流式 AI 回复） → `turn.completed`
- 统一业务入口 `submitTurn` / `submitTurnStream` 同时服务 HTTP 和 WebSocket，避免两套逻辑产生评分差异（事实，`session_actions.go:33-37` 注释明确说明）

#### 3. Qwen Omni WebSocket Realtime 语音链路（事实，`api/voice.go`）
- 浏览器 `getUserMedia` + `AudioContext` 采集 PCM 16kHz 音频
- 前端连本地 `/api/sessions/{id}/voice` WebSocket
- Go 服务端用后端 API Key 连接 DashScope Qwen Omni，做双向代理：前端事件 → `normalizeVoiceClientEvent` 转换 → 远端；远端事件 → 透传前端
- 语音 Provider 未配置时返回 `voice.error` 并关闭连接（`voice.go:63-67`）
- 场景音色选择有规则引擎：`selectVoiceForScenario` 按 coachRole/role/title 关键词匹配 10 种音色（Tina/Cindy/Ethan/Raymond 等），`scenarioVoiceRules` 定义中文/英文关键词到音色的映射（事实，`voice.go:267-395`）

### 数据模型
- `Scenario`（场景配置，36 行 struct，`scenario/model.go`）：60 个 JSON 文件，含 goals/keywords/successCriteria/suggestedPhrases/scoreDimensions
- `PracticeSession`（会话聚合，`session/model.go:19-33`）：含 Turns、Summary、Metrics、LearningAssets
- `DialogueTurn`（一轮对话，`session/model.go:36-54`）：含 Corrections、ExpressionTips、Pronunciation、VoiceTurnMetadata、FeedbackTiming/Severity/FocusArea
- `SessionSummary`（课后报告，`session/model.go:107-123`）：含 OverallScore、Level、DetailedMetrics、Strengths、FocusAreas、CoreDefects、TypicalErrors、TrainingPlan
- 前后端共享契约：`packages/shared/src/index.ts`（258 行）定义全部 TypeScript 类型，Go 后端保持相同 JSON 字段（事实，shared/src/index.ts:1-2 注释）

### 存储设计
- SQLite 默认：`sessions` 表以 `payload TEXT`（JSON 序列化整个 PracticeSession）+ 索引字段（id/scenario_id/status/started_at/turn_count）存储，`ON CONFLICT(id) DO UPDATE` 实现 upsert（事实，`sqlite_session_store.go:99-129`）
- JSON 兜底：旧版 `SessionStore` 用文件 + mutex，SQLite 首次启动时空库自动从 `sessions.json` 导入历史数据（事实，`sqlite_session_store.go:169-209` `importLegacyJSON`）
- 迁移：`CREATE TABLE IF NOT EXISTS` + `CREATE INDEX IF NOT EXISTS`，无版本管理（事实，`sqlite_session_store.go:148-167`）

### 安全设计
- 语音 API Key 只放后端环境变量，README 和 .env.example 明确警告"不要创建 VITE_* 语音密钥变量"（事实，.env.example:22-23）
- 前端只连本地 Go 服务，长期密钥始终保留在后端（事实，`voice/provider.go:79-80` 注释）
- CORS 中间件支持 Vite 开发跨端口（事实，`api/server.go:79` `withCORS`）
- 注意：当前无用户认证/鉴权机制，是本地单用户 MVP 设计（推断，所有 API 无 auth 中间件）

## 工程质量评分（1-5）

| 维度 | 分数 | 依据 |
|------|------|------|
| 1. 代码组织与模块化 | 5 | Monorepo 清晰分层（apps/web、apps/server、packages/shared），后端按领域分包（api/coach/scenario/session/speech/storage/realtime/voice/config），每个包职责单一。Provider 接口抽象到位，API 层只依赖接口。 |
| 2. 架构设计 | 5 | Provider 可替换 + 全链路 fallback 是成熟设计。Dependencies struct 全接口注入，NewServer 对 nil 依赖提供默认值（`server.go:57-68`），测试友好。HTTP 和 WebSocket 共享 `submitTurn` 统一入口避免逻辑分叉。 |
| 3. 代码质量与可读性 | 4 | Go 代码注释充分（中文注释说明设计意图），函数命名清晰。但 `openai_compatible.go` 1388 行偏大，prompt 构建、JSON 修复、流式解析混在一个文件。前端 `I18nProvider.tsx` 1863 行、`SummaryPage.tsx` 1197 行、`PracticeRoomPage.tsx` 1014 行偏大。 |
| 4. 测试覆盖 | 4 | 14 个 Go 测试文件、38 个 Test 函数，覆盖 config/speech/storage/coach/api 各层。但前端 0 测试文件（`find apps/web -name "*.test.*"` 为空），rule_based_test.go 仅 3 个测试。 |
| 5. 错误处理与健壮性 | 5 | 全链路 fallback：LLM 失败降 rule、语音未配置降 disabled、翻译失败降 quick-local、SQLite 失败可降 JSON。`clampNonNegative`/`clamp` 等防御性函数。`context.Done()` 检查贯穿所有 Provider。LLM 返回空内容也触发 fallback（`openai_compatible.go:211-216`）。 |
| 6. 数据模型设计 | 4 | 领域模型完整（Scenario/Session/Turn/Summary/LearningAsset），嵌套结构合理。SQLite 用 JSON payload 牺牲了字段级查询能力，但降低了 schema 迁移成本，对 MVP 合理。 |
| 7. API 设计 | 4 | RESTful + WebSocket 双通道，HTTP 端点清晰（health/scenarios/sessions/learning-assets）。WebSocket 事件协议完整（8 种事件类型，shared/index.ts:200-257）。但路由用 `strings.Split` 手动解析嵌套路径（`server.go:218-251`），扩展性有限。 |
| 8. 文档质量 | 4 | README 24KB 极详尽（设计理念/功能总览/技术栈/架构图/核心链路时序图/数据模型/API 契约/配置/启动/故障排查/安全/路线图），docs/architecture.md 和 docs/api.md 补充。PR 模板规范。但 README 的开发过程 claims 因 git 历史压缩不可验证。 |
| 9. 可复用性 | 4 | Provider 接口和兜底实现可直接复用到其他 AI 对话产品。`packages/shared` 契约模式可复用。60 个场景 JSON 是领域资产。但场景结构和 prompt 强绑定口语训练，跨领域复用需改造。 |
| 10. 可维护性 | 4 | 分层清晰、接口抽象、统一业务入口，维护成本低。但单文件过大（openai_compatible.go 1388 行、I18nProvider.tsx 1863 行）是维护隐患。无 CI/CD 配置文件可见。 |
| 11. 性能与可扩展性 | 3 | 本地单进程 MVP，MemoryHub 仅支持单实例 pub/sub，SQLite 单文件。无水平扩展设计。Voice WS 代理用双 goroutine 中继，有音频块计数日志但无背压机制。对 MVP 定位合理，但生产化需重构。 |

**综合工程分：4.4 / 5**

## 优势与不足

### 优势
1. **Provider 可替换架构是教科书级设计**：五类能力全部接口化 + 兜底实现，无密钥可完整运行，替换厂商不改页面流程（事实，`main.go` 全部 build*Provider 函数）。
2. **产品闭环完整**：从目标诊断 → 今日任务 → 场景练习 → 实时反馈 → 课后报告 → 学习库沉淀 → 成长追踪，7 步闭环全部有代码实现，不是 PPT（事实，8 个页面 + 60 场景 + 完整后端）。
3. **fallback 链路纵深**：不只是顶层 Provider 降级，LLM 单次调用失败也降级到 rule（`openai_compatible.go:190-195`），甚至 LLM 返回空内容也降级（`211-216`），翻译 Provider 失败降 quick-local（`translation.go:55-63`）。
4. **统一业务入口**：`submitTurn`/`submitTurnStream` 同时服务 HTTP 和 WebSocket，注释明确"避免两套逻辑产生评分或保存差异"（事实，`session_actions.go:33-37`），是防止一致性 bug 的关键设计。
5. **语音链路安全**：API Key 后端持有，前端只连本地服务，README 和 .env.example 双重警告（事实）。
6. **Go 依赖极简**：仅 2 个直接依赖，无 Web 框架、无 ORM，降低供应链风险。
7. **场景音色规则引擎**：按场景角色关键词自动选择匹配音色（面试官→Raymond，教授→Theo Calm），提升角色扮演沉浸感（事实，`voice.go:312-395`）。

### 不足
1. **Git 历史被压缩**：仅 1 个 commit，开发过程不可追溯，README 的 47 commits/14 PRs 类 claims 无法验证（事实，`git log --all --oneline`）。
2. **前端零测试**：26 个 TS/TSX 文件无任何测试文件，关键 hook（useRealtimeSession/useOmniRealtimeVoiceSession）和页面（PracticeRoomPage 1014 行）缺乏回归保护（事实，`find apps/web -name "*.test.*"` 为空）。
3. **单文件过大**：`openai_compatible.go` 1388 行（prompt + JSON 修复 + 流式 + 翻译 + 脚手架 + 自定义场景规划全在一个文件），`I18nProvider.tsx` 1863 行（全部 i18n 文案），`SummaryPage.tsx` 1197 行，`useOmniRealtimeVoiceSession.ts` 956 行（事实，`wc -l`）。
4. **无用户认证**：本地 MVP 定位合理，但产品化需补 auth 层（推断，无任何 auth 中间件）。
5. **无 CI/CD**：无 `.github/workflows` 可见，测试需手动运行（事实，目录树无 workflows）。
6. **SQLite JSON payload 牺牲查询能力**：无法按 turn 级别字段查询，LearningAssets 需全量 List 后内存过滤（事实，`learning_assets.go:44-58` 遍历所有 session 的所有 asset）。
7. **路由手动解析**：`strings.Split` 解析嵌套路径（`server.go:218-251`），不如使用 mux/chi 等路由器健壮。

## 可复用性矩阵

### 可复用资产
| 资产 | 路径 | 复用价值 | 说明 |
|------|------|---------|------|
| Provider 可替换架构模式 | `apps/server/internal/*/provider.go` + `main.go` build*Provider | 高 | 五类能力接口化 + fallback 的完整范式，可直接套用到任何 AI 产品 |
| 共享契约模式 | `packages/shared/src/index.ts` | 高 | 前后端 TypeScript/Go JSON 字段对齐的契约层设计 |
| 统一业务入口模式 | `api/session_actions.go:33-37` | 高 | HTTP 和 WebSocket 共享 submitTurn 防一致性 bug |
| 场景配置结构 | `data/scenarios/*.json` | 中 | 60 个结构化口语训练场景，含 goals/keywords/scoreDimensions |
| WebSocket 实时事件协议 | `realtime/hub.go` + `shared/index.ts:200-257` | 中 | 8 种事件类型的 pub/sub 协议，可复用于其他实时对话产品 |
| LLM JSON 修复 + fallback | `openai_compatible.go` Respond/Summarize | 中 | LLM 返回空/异常时降级到 rule 的完整模式 |
| 语音 WS 代理 | `api/voice.go` | 中 | 后端持 Key 做双向 WS 中继的安全模式 |
| 场景音色规则引擎 | `voice.go:312-395` | 低-中 | 关键词→音色映射，领域特定但模式可复用 |
| Browser 发音评估 | `speech/browser_provider.go` | 低 | 基于转写+置信度+时长的轻量评估，非声学级 |

### 不可复用部分
- 口语训练专用 prompt（`openai_compatible.go:651-825` 的 turnSystemPrompt/summarySystemPrompt 等）强绑定英语口语场景
- 60 个场景内容本身是领域资产，不可跨领域复用
- 前端页面（PracticeRoom/Summary/Progress）强绑定口语训练 UI 流程
- `learningPlan.ts` 的 `goalScenarioIDs` 映射强绑定本项目场景 ID

## 可学习内容

1. **Provider 可替换 + 全链路 fallback**：从 main.go 装配到单次 LLM 调用，每一层都有降级路径，是 AI 产品工程化的核心模式。
2. **统一业务入口**：HTTP 和 WebSocket 共享 `submitTurn`，用注释明确设计意图，是防止多通道一致性问题 的有效手段。
3. **无密钥可运行**：RuleBasedCoach + DisabledProvider + BrowserAssessmentProvider 让项目零配置启动，对演示、测试、CI 友好。
4. **语音 API Key 后端代理**：前端只连本地服务，长期密钥不出后端，是语音类产品的安全基线。
5. **可解释状态**：练习房间显式展示连接/麦克风/字幕/AI 状态/fallback 原因，是 AI 产品用户体验的关键设计。
6. **Go 标准库路由 + 手动解析**：适合 MVP 但不宜用于生产，可作为"何时该引入路由框架"的反面教材。
7. **SQLite JSON payload 模式**：用 JSON 列存储聚合根，牺牲字段级查询换取 schema 灵活性，适合 MVP 但需评估查询需求。

```yaml
project: EnglishPartner
one_line_judgment: 产品完成度极高的 AI 英语口语陪练，Go+React+Provider 可替换架构，全链路 fallback 无密钥可运行，本批产品设计的系统化标杆
product_type: AI 英语口语训练工具（本地优先 MVP）
target_users: 中国英语学习者（面试/考试/职场/留学/旅游/兴趣场景）
core_loop: 目标诊断→今日任务→场景对话→实时反馈→课后报告→学习库沉淀→成长追踪
architecture_style: Provider 可替换的分层单体，本地优先，接口注入 + 全链路 fallback
stack:
  backend: Go 1.22 + net/http + coder/websocket + modernc.org/sqlite + SQLite
  frontend: React 18 + TypeScript + Vite 5 + React Router 6 + lucide-react + WebSocket API + Web Audio API
  shared: packages/shared TypeScript 契约（258 行）
  ai: OpenAI-compatible Chat Completions + Qwen Omni WebSocket Realtime + 腾讯云 TMT
  deps: 后端仅 2 个直接依赖（coder/websocket + modernc.org/sqlite）
strongest_patterns:
  - Provider 可替换 + 全链路 fallback（5 类能力接口化 + 兜底实现）
  - 统一业务入口 submitTurn 服务 HTTP+WebSocket 双通道
  - 无密钥可运行（RuleBasedCoach + DisabledProvider + BrowserAssessment）
  - 语音 API Key 后端代理（前端只连本地服务）
  - 场景音色规则引擎（关键词→音色自动匹配）
main_risks:
  - Git 历史被压缩（仅 1 commit），开发过程不可追溯
  - 前端零测试（26 个 TS/TSX 文件无测试）
  - 单文件过大（openai_compatible.go 1388 行、I18nProvider.tsx 1863 行）
  - 无用户认证（本地 MVP 合理但产品化需补）
  - 无 CI/CD
  - SQLite JSON payload 牺牲字段级查询能力
business_scenarios:
  - 英语口语面试训练（interview/behavioral-follow-up/salary-negotiation 等 10 场景）
  - 考试口语练习（CET/IELTS/TOEFL/考研复试 10 场景）
  - 职场英语（meeting/client-update/deadline-negotiation 等）
  - 旅游/留学/兴趣交流场景
  - 自定义场景（LLM 规划场景结构）
reusable_assets:
  - Provider 可替换架构模式（5 类能力接口 + fallback）
  - 共享契约模式（packages/shared TypeScript + Go JSON 对齐）
  - 统一业务入口模式（submitTurn 服务 HTTP+WebSocket）
  - WebSocket 实时事件协议（8 种事件类型）
  - LLM JSON 修复 + fallback 模式
  - 语音 WS 后端代理安全模式
  - 60 个结构化口语场景 JSON
non_reusable_parts:
  - 口语训练专用 prompt（turnSystemPrompt/summarySystemPrompt 等）
  - 60 个场景内容（领域资产）
  - 前端页面（PracticeRoom/Summary/Progress 强绑定口语 UI）
  - learningPlan.ts goalScenarioIDs 映射
scores:
  product: 5
  architecture: 5
  engineering: 4
  reuse: 4
  commercialization: 3
evidence:
  - path: apps/server/cmd/server/main.go
    lines: 46-137
    note: buildSessionStore/buildCoachProvider/buildSpeechProvider/buildVoiceProvider 全部有 fallback 逻辑（事实）
  - path: apps/server/internal/api/server.go
    lines: 43-68
    note: Dependencies struct 全接口，NewServer 对 nil 依赖提供默认值（事实）
  - path: apps/server/internal/coach/openai_compatible.go
    lines: 180-220
    note: LLM 调用失败或返回空 assistantText 时降级到 fallback rule 教练（事实）
  - path: apps/server/internal/api/session_actions.go
    lines: 33-37
    note: submitTurn 统一业务入口，注释明确避免 HTTP/WS 两套逻辑产生评分差异（事实）
  - path: apps/server/internal/voice/provider.go
    lines: 40-69
    note: DisabledProvider 兜底实现，未配置语音密钥时后端仍可启动（事实）
  - path: apps/server/internal/api/voice.go
    lines: 36-112
    note: 语音 WS 后端代理，API Key 后端持有，前端只连本地服务（事实）
  - path: apps/server/internal/api/voice.go
    lines: 312-395
    note: 场景音色规则引擎 scenarioVoiceRules，10 种音色按关键词匹配（事实）
  - path: apps/server/internal/realtime/hub.go
    lines: 56-126
    note: Hub 接口 + MemoryHub 进程内 pub/sub，按 sessionID 广播（事实）
  - path: apps/server/internal/storage/sqlite_session_store.go
    lines: 99-167
    note: SQLite JSON payload + upsert + IF NOT EXISTS 迁移（事实）
  - path: packages/shared/src/index.ts
    lines: 1-258
    note: 前后端共享 TypeScript 契约，8 种 WebSocket 事件类型定义（事实）
  - path: apps/web/src/features/voice/useOmniRealtimeVoiceSession.ts
    lines: 1-80
    note: 前端语音 hook，PCM 16kHz 采集 + WS 中继（事实）
  - path: .env.example
    lines: 22-23
    note: 明确警告 API Key 只放后端，不要创建 VITE_* 语音密钥变量（事实）
  - path: git log --all --oneline
    note: 仅 1 个 commit，README 开发过程 claims 不可验证（事实）
  - path: find apps/web -name "*.test.*"
    note: 前端零测试文件（事实）
  - path: wc -l apps/server/internal/coach/openai_compatible.go
    note: 1388 行单文件，prompt+JSON 修复+流式+翻译+脚手架混杂（事实）
confidence: high
```
