# ai-speaking-coach (lingo coach) 项目审查报告

## 一句话判断

一款面向中文用户的 AI 英语口语陪练 Web 应用，采用 Node.js 业务后端 + Python Pipecat Voice Agent 双轨架构，核心创新是"连续对话动态追问 + 七维量化评分 + LLM 输出深度归一化防御层"；mock/live 双模式零 Key 可演示，产品闭环完整，但 App.tsx 巨型组件、内存会话无持久化、CORS 全开放是主要工程短板。

## 项目地图

- **语言/框架**：React 19 + TypeScript（strict）+ Vite（前端）；Node.js + Express 5（业务后端）；Python + Pipecat + SmallWebRTC（Voice Agent）
- **核心依赖**：`@pipecat-ai/client-js` + `@pipecat-ai/small-webrtc-transport`（浏览器侧 WebRTC）、`openai` SDK（OpenAI-compatible LLM）、`zod`（schema 校验）、`vitest` + `supertest`（测试）、`multer`（音频上传）、`lucide-react`（图标）
- **入口**：`src/main.tsx` → `src/App.tsx`（1054 行，单组件多屏状态机）；`server/index.ts` → `server/app.ts`（Express）；`pipecat_service/server.py` → `bot.py`（Pipecat Pipeline）
- **目录边界**：
  - `src/` — React 前端（App + components + domain + copy + api + pipecatVoiceClient）
  - `server/` — Node Express 业务后端（app/config/practiceSession/data/sessionStore + providers/）
  - `shared/schemas.ts` — 前后端共享 zod schema（coachState/transcript/dialogueTurn/report/session）
  - `pipecat_service/` — Python Pipecat Voice Agent（bot.py pipeline + server.py SmallWebRTC）
  - `tests/` — 16 个测试文件
  - `docs/` — 产品需求/UI 信息架构/视觉设计/教练交互/开发计划/开发日志
- **部署形态**：三服务手动启动 — Vite(:5173) + Node API(:5174) + Pipecat(:7860)
- **规模**：TS/TSX 约 7414 行，Python 约 337 行，16 个测试文件
- **API 模式**：`API_MODE=mock`（默认零 Key）/ `live`（AssemblyAI ASR + hezu OpenAI-compatible LLM + Cartesia TTS）；预设 `global-mixed` / `china-qwen` / `custom`

## 产品与商业场景

- **目标用户**：需要英语口语练习的中文用户，覆盖面试、会议、点餐场景，支持自定义场景/AI 角色/任务目标/开场问题（事实，README:3,29）
- **核心闭环**：选择场景（内置+自定义）→ 选 3/5/7/10 分钟 → 进入训练房间连接 Pipecat Voice Agent → VAD 断句连续对话 + AI 动态追问 → 结束训练 → 生成一页式课后报告（七维评分 + 句子纠错 + 表达优化 + 发音技巧 + 推荐重练句）→ 首页打卡 + 成长轨迹（事实，README:3-5,242-245）
- **独特价值**：从"固定 5 轮题库问答"改为"5-7 分钟连续对话 + AI 基于上下文动态追问"（事实，README:34）；七维量化评分（fluency/pronunciation/grammar/vocabulary/coherence/task_completion/interaction）比单一总分更有指导意义（事实，schemas.ts:52-60）
- **打动评委的瞬间**：训练房间连续对话，AI 围绕项目背景/职责/技术方案/结果/反思持续追问；结束后一页式七维雷达图 + 原句/优化句对比 + 推荐重练分块练习（事实，README:242-245）
- **商业化**：付费方为英语学习个人用户；连续打卡 + 火花状态 + 成长轨迹形成持续使用理由（合理推断）

## 架构拆解

```
┌─ React 前端 (:5173) ──────────────────────────────────────┐
│  App.tsx (1054行, screen 状态机: home/prep/practice/report) │
│  ├── home: MascotAvatar + WeekDots + VALUE_CARDS           │
│  ├── prep: 场景选择 + 时长选择 + 自定义场景表单              │
│  ├── practice: pipecatVoiceClient (WebRTC) + 实时字幕       │
│  └── report: ReportDashboard (七维雷达 + 纠错 + 重练)       │
└────────────┬──────────────────────────┬───────────────────┘
             │ HTTP JSON /api/*         │ WebRTC /api/offer
             ▼                          ▼
┌─ Node Express (:5174) ──────┐  ┌─ Python Pipecat (:7860) ──────┐
│ practice_session CRUD       │  │ SmallWebRTCTransport           │
│ /api/session/start          │  │   ↓                            │
│ /api/session/:id/turns      │  │ Pipeline:                      │
│ /api/session/:id/end        │  │  transport.input               │
│ /api/asr/transcribe (multer)│  │  → user_idle (6s→TTS 提示)     │
│ /api/llm/turn               │  │  → STT (AssemblyAI)            │
│ /api/tts/synthesize         │  │  → user_aggregator             │
│ /api/report/generate        │  │  → LLM (OpenAI-compat, temp0.7)│
│ /api/settings (运行时切换)   │  │  → AssistantTurnPublisher ──┐  │
│                             │  │  → TTS (Cartesia)           │  │
│ providers/liveProviders.ts  │  │  → transport.output         │  │
│  (mock/live + 归一化防御)    │  │  → assistant_aggregator      │  │
│ providers/mockProviders.ts  │  │                              │  │
│ practiceSession.ts (内存Map)│  │ onServerMessage: conversation│  │
│ shared/schemas.ts (zod)     │  │  _turn 回传浏览器 ──────────┼──┘
└─────────────────────────────┘  └──────────────────────────────┘
                   ▲                              │
                   └── /api/session/:id/turns ────┘
                       (Pipecat 转写/AI发言写回业务API)
```

**双轨架构核心**（事实）：Node Express 处理业务会话 + 报告生成（请求-响应），Python Pipecat 处理实时语音对话（WebRTC 流式）。两轨通过 `AssistantTurnPublisher`（bot.py:79-111）桥接 —— 它拦截 `LLMFullResponseEndFrame`，将 AI 完整发言作为 `conversation_turn` server message 推回浏览器，浏览器 `pipecatVoiceClient.ts:157-159` 接收后调 `/api/session/:sessionId/turns` 持久化。

**Pipecat Pipeline 调用链**（bot.py:182-201）：
`transport.input` → `user_idle`（IdleFrameProcessor 6s 超时 → `TTSSpeakFrame("Take your time...")`，bot.py:176-180）→ `stt`（AssemblyAISTTService，`min_turn_silence=800, max_turn_silence=1200`，bot.py:131-138）→ `user_aggregator`（LLMContext 累积上下文）→ `llm`（OpenAILLMService，`temperature=0.7, max_completion_tokens=180`，system_instruction 含场景/目标/教学策略，bot.py:140-149）→ `AssistantTurnPublisher`（拦截 LLM 帧发 server message）→ `tts`（CartesiaTTSService）→ `transport.output` → `assistant_aggregator`

**报告生成与归一化防御层**（liveProviders.ts:678-700+）：
1. LLM 返回 JSON → `parseJsonContent` 剥 markdown fence + 提取首个 `{...}`（liveProviders.ts:329-339）
2. `normalizeReportJson`：`readDimensionId` 模糊匹配中英文维度名（liveProviders.ts:553-564）；`normalizeScoreScale` 处理 0-1/0-10/0-100 量纲（liveProviders.ts:547-551）；`clampScore` 0-100（liveProviders.ts:543-545）；`alignDimensionScoresToTotal` 当维度均值与总分差≥4 时整体平移（liveProviders.ts:585-595）
3. `normalize*` 系列对 sentenceAnalyses/pronunciationTips/evidenceTurns/nextPractice 做多字段名别名容错（original|originalText、improved|improvedText|better 等，liveProviders.ts:597-676）
4. zod `reportResultSchema.parse` 最终校验（schemas.ts:107-122）

**三级降级链**（事实）：
- L1：`API_MODE=mock` → `mockProviders` 全量 mock（mockTranscribe/mockDialogueTurn/mockSpeech，mockProviders.ts:21-87）
- L2：`API_MODE=live` 但缺 Key / 调用失败 → 回退 mock + `fallbackReason`（liveProviders.ts:67-72,88-89,419-423,480-485）
- L3：报告 LLM 输出残缺 → `normalize*` 填充 + `reportDiagnostics` 兜底（reportDiagnostics.ts:49-170：sentenceAnalyses 空则从 corrections 生成；evidenceTurns 空则取最后 3 条 user turn；pronunciationTips 空则关键词匹配；nextPractice 空则从 suggestions 提取）

**会话生命周期**（practiceSession.ts）：
- `practice_session` 含 `conversation_turns[]`，status: `running → paused → completed/expired`（practiceSession.ts:36-58,74-92）
- `PracticeSessionStore` 内存 Map，无持久化（practiceSession.ts:105-106）
- 时长仅允许 3/5/7/10 分钟（practiceSession.ts:15）

## 工程评分（1-5）

| 维度 | 分数 | 证据 |
|------|------|------|
| 产品完成度 | 4 | 场景选择+连续对话+七维报告+成长打卡，闭环完整可演示（README:27-36） |
| 架构边界 | 4 | Node 业务后端 + Pipecat Voice Agent 分离；shared/schemas 前后端共享契约；但 App.tsx 巨型组件拉低内聚 |
| 可维护性 | 3 | App.tsx 1054 行单组件管 4 屏+全部状态；三服务部署增加复杂度；liveProviders.ts 1226 行单文件 |
| 可测试性 | 4 | 16 个测试文件（api.test.ts 439 行/settings.test.ts 180 行）；Vitest + Supertest；typecheck + build |
| 可观测性 | 3 | Pipecat `enable_metrics=True`（bot.py:198）；但 Node 侧仅基础日志，无结构化日志/指标 |
| 安全隐私 | 3 | 密钥仅 Node 运行内存不写浏览器（README:221）；但 CORS * 全开放（app.ts:53）；/api/settings POST 无鉴权（app.ts:64-67） |
| 性能并发 | 3 | WebRTC 实时通信；但内存会话无并发保护；无 rate limit |
| 资源释放 | 3 | pipecatVoiceClient disconnect 清理 audio 元素（pipecatVoiceClient.ts:177-182）；Pipecat worker.cancel on disconnect（bot.py:209-211） |
| 成本控制 | 4 | mock 零 Key + live 缺 Key 回退 mock；LLM max_completion_tokens=180 限长（bot.py:147） |
| 部署恢复 | 2 | 需手动启动三服务（Vite+Node+Pipecat）；无 Docker；无 CI；内存会话重启丢失 |
| 文档 | 4 | README 详尽 + 产品需求/UI架构/视觉设计/教练交互/开发计划/开发日志 6 份文档 |
| 上手难度 | 3 | 需 Node 20+ + Python + 多 API Key（或 mock）；三服务端口配置 |

## 优点

1. **七维量化评分体系**（事实）：fluency/pronunciation/grammar/vocabulary/coherence/task_completion/interaction，每维含 labelZh/labelEn/score/explanationZh（schemas.ts:51-65）。比单一总分更有指导意义，七维雷达图直观展示强弱项。

2. **连续对话动态追问（产品创新）**（事实）：从固定 5 轮题库改为 3/5/7/10 分钟连续对话（practiceSession.ts:15），Pipecat `LLMContext` 累积完整上下文（bot.py:160-171），system_instruction 要求"一次只问一个短追问，保持会话流动"（bot.py:46-71）。更接近真实口语练习。

3. **LLM 输出深度归一化防御层**（事实）：`liveProviders.ts` 的 `normalizeReportJson` + `normalize*` 系列（liveProviders.ts:678-676）对 LLM 返回做极强的容错：markdown fence 剥离、多字段名别名、量纲归一化、维度模糊匹配、残缺字段填充。这是对抗 LLM 输出不确定性的工程范本。

4. **mock/live 双模式 + 缺 Key 自动回退**（事实）：`API_MODE=mock` 默认零 Key 演示（config.ts:134）；live 模式缺 Key 或调用失败时每个 provider 都回退 mock + `fallbackReason`（liveProviders.ts:67-72,88-89,419-423,480-485）。保证演示永不中断。

5. **可替换三段式 API 链路 + 预设体系**（事实）：ASR/LLM/TTS 各段独立可替换，三套预设（global-mixed/china-qwen/custom，config.ts:51-88）；支持 OpenAI/通义千问/豆包/Kimi 四种 LLM provider + 别名 Key 解析（config.ts:125-131）；运行时可通过 `/api/settings` 热切换（config.ts:185-251）。

6. **Pipecat Voice Agent 集成 + 自定义 FrameProcessor**（事实）：`AssistantTurnPublisher`（bot.py:79-111）继承 `FrameProcessor`，拦截 `LLMFullResponseStartFrame/LLMTextFrame/LLMFullResponseEndFrame` 聚合 AI 完整发言，通过 `OutputTransportMessageFrame` + RTVI ServerMessage 回传浏览器。是 Pipecat 框架自定义 frame 处理的干净实践。

7. **reportDiagnostics 兜底链**（事实）：`createReportDiagnostics`（reportDiagnostics.ts:21-47）对报告每个可选字段都有 fallback：sentenceAnalyses 空则从 corrections 推导（49-63）；evidenceTurns 空则取最后 3 条 user turn（89-106）；pronunciationTips 空则关键词匹配 project/model/maybe（108-153）；nextPractice 空则从 suggestions 提取 + 自动分块（155-180）。保证报告 UI 永不空白。

## 缺点、风险与改进优先级

| 级别 | 问题 | 证据/影响 | 修复方向 |
|------|------|-----------|----------|
| P0 | 内存会话无持久化 | `PracticeSessionStore` 用 Map（practiceSession.ts:106）；server 重启丢失所有会话和对话 | 持久化到 SQLite/文件/Redis |
| P1 | App.tsx 巨型组件 | 1054 行单组件管 4 屏 + 全部状态 + WebRTC 生命周期 + 倒计时 + 转写滚动（App.tsx:93-120）；难维护难测试 | 拆分为 Home/Prep/Practice/Report 四组件 + 状态管理 |
| P1 | /api/settings 无鉴权可写入 API Key | app.ts:64-67 POST 无 auth；任意来源可注入 Key 到运行时内存 | 加鉴权或限制 localhost |
| P1 | CORS * 全开放 | app.ts:53 `app.use(cors())` 无 origin 限制 | 限制 origin 为前端域名 |
| P2 | Qwen ASR 伪造词级时间戳/置信度 | liveProviders.ts:302-311：`start: index*0.35, confidence: 0.9` 硬编码，非真实 word-level | 标注为非词级或接入真实词级 ASR |
| P2 | 无 rate limiting | /api/* 无限流；/api/report/generate 可被滥用 | 加 express-rate-limit |
| P2 | Pipecat bot.py 服务硬编码 | bot.py:131-158 硬编码 AssemblyAI/Cartesia/OpenAI，env-first 但无 Node 侧的 provider 切换 | 对齐 Node 侧预设体系或文档化限制 |
| P2 | 双轨 LLM 调用路径冗余 | Node /api/llm/turn（liveProviders.ts:375）与 Pipecat LLM（bot.py:140）是两条并行 LLM 路径，mock 模式用前者、live 用后者 | 明确职责边界或统一入口 |
| P3 | `alignDimensionScoresToTotal` 静默调整分数 | liveProviders.ts:585-595：维度均值与总分差≥4 时整体平移，可能掩盖 LLM 评分不一致 | 记录调整日志或让 LLM 自洽 |
| P3 | 无 Docker / 无 CI | 手动启动三服务；有测试但无 CI 配置 | docker-compose + GitHub Actions |
| P3 | liveProviders.ts 1226 行单文件 | 所有 ASR/LLM/TTS provider 适配 + 归一化逻辑挤在一个文件 | 按 provider 拆分 |

## 复用性矩阵

| 维度 | 分数 | 说明 |
|------|------|------|
| 技术复用 | 4 | 七维评分 schema + LLM 归一化防御层 + mock/live 双模式可直接复用 |
| 产品复用 | 3 | 口语陪练产品闭环完整但同质化较高 |
| 商业复用 | 3 | 英语口语学习市场有需求，但个人付费意愿中等 |

- **可直接复用**：
  - 七维评分 zod schema（`shared/schemas.ts` scoreDimensionSchema/reportResultSchema）—— 任何"多维度量化评估"场景
  - LLM 输出归一化防御层（`liveProviders.ts` normalizeReportJson + normalize* 系列）—— 对抗 LLM 输出不确定性的通用模式
  - mock/live 双模式 + 缺 Key 回退模式（`config.ts` + `liveProviders.ts`）—— 任何需要第三方 API 的演示型项目
  - reportDiagnostics 兜底链模式（`reportDiagnostics.ts`）—— 报告字段残缺时的多级 fallback
  - Pipecat `AssistantTurnPublisher` 自定义 FrameProcessor 模式（`bot.py:79-111`）—— Pipecat 管道中拦截/聚合 frame 回传客户端
- **改造后复用**：三段式可替换 API 链路（ASR/LLM/TTS 预设体系）；Pipecat Voice Agent 集成骨架
- **不应复用**：App.tsx 巨型组件结构；内存会话存储；CORS * 三服务手动部署架构

## 值得学习的内容

1. **LLM 输出深度归一化防御层**（进阶者）：`liveProviders.ts:678-676` — 对 LLM 返回做极强容错：markdown fence 剥离、多字段名别名（original|originalText、improved|improvedText|better）、量纲归一化（0-1/0-10/0-100）、维度模糊匹配（中英文）、残缺字段填充。核心思想：永远不信任 LLM 输出格式，在数据边界做全面归一化。可迁移到任何消费 LLM JSON 输出的项目。

2. **mock/live 双模式 + 缺 Key 自动回退**（可迁移）：`config.ts:134` + `liveProviders.ts` 每个 provider 的 `if (config.apiMode !== "live" || !config.xxxApiKey) return mock` 模式。保证演示永不中断，且 fallbackReason 可追溯。

3. **reportDiagnostics 多级兜底链**（可迁移）：`reportDiagnostics.ts:21-180` — 报告每个可选字段都有 fallback 生成逻辑，从其他字段或原始对话推导。保证报告 UI 永不空白，用户体验稳定。

4. **七维量化评分体系设计**（产品）：`schemas.ts:51-65` — fluency/pronunciation/grammar/vocabulary/coherence/task_completion/interaction 七维，每维含中英文标签+分数+解释。比单一总分更有指导意义，雷达图直观。

5. **Pipecat 自定义 FrameProcessor**（进阶者）：`bot.py:79-111` — 继承 `FrameProcessor`，在 pipeline 中拦截 `LLMFullResponseEndFrame` 聚合 AI 发言，通过 `OutputTransportMessageFrame` 回传客户端。是 Pipecat 框架扩展点的干净实践。

6. **连续对话 vs 固定题库的产品设计转变**（产品）：`bot.py:43-71` system_instruction — "不要用固定轮次/测验/编号问题，一次只问一个短追问，保持会话流动"。从题库问答到上下文追问的产品思路转变。

## 结构化摘要

```yaml
project: ai-speaking-coach
one_line_judgment: "AI英语口语陪练Web应用，Node+Pipecat双轨架构，七维评分+连续对话动态追问+LLM输出深度归一化防御层+mock/live双模式，产品闭环完整但App.tsx巨型组件/内存会话/CORS全开放是工程短板"
product_type: "教育/AI口语陪练"
target_users: ["需要英语口语练习的中文用户(面试/会议/点餐/自定义场景)"]
core_loop: "选择场景(内置+自定义) -> 选3/5/7/10分钟 -> Pipecat WebRTC连续对话(VAD断句+AI动态追问) -> 结束训练 -> 一页式课后报告(七维评分+句子纠错+表达优化+发音技巧+推荐重练) -> 首页打卡+成长轨迹"
architecture_style: "Node.js业务后端(Express) + Python Pipecat Voice Agent(SmallWebRTC) + React前端 双轨架构; Pipecat AssistantTurnPublisher桥接实时轨与业务轨; shared/schemas前后端共享zod契约"
stack: ["React19", "TypeScript(strict)", "Vite", "Node.js", "Express5", "Python", "Pipecat", "SmallWebRTC", "openai SDK", "zod", "vitest", "supertest", "multer", "lucide-react", "AssemblyAI", "hezu OpenAI-compatible", "Cartesia"]
strongest_patterns:
  - "七维量化评分体系(fluency/pronunciation/grammar/vocabulary/coherence/task_completion/interaction)"
  - "连续对话动态追问(非固定题库,LLMContext累积上下文,system_instruction约束一次一追问)"
  - "LLM输出深度归一化防御层(parseJsonContent+normalizeReportJson+normalize*系列,多字段名别名+量纲归一+维度模糊匹配+残缺填充)"
  - "mock/live双模式+缺Key自动回退mock+fallbackReason可追溯"
  - "可替换三段式API(ASR/LLM/TTS)+三预设(global-mixed/china-qwen/custom)+运行时热切换"
  - "Pipecat AssistantTurnPublisher自定义FrameProcessor(拦截LLM帧聚合AI发言回传浏览器)"
  - "reportDiagnostics多级兜底链(sentenceAnalyses/evidenceTurns/pronunciationTips/nextPractice各有fallback)"
  - "密钥仅Node运行时内存不写浏览器持久化"
main_risks:
  - "P0:内存会话无持久化(PracticeSessionStore Map,重启丢失)"
  - "P1:App.tsx 1054行巨型组件管4屏+全部状态"
  - "P1:/api/settings无鉴权可写入API Key"
  - "P1:CORS *全开放"
  - "P2:Qwen ASR伪造词级时间戳/置信度"
  - "P2:无rate limiting"
  - "P2:Pipecat bot.py服务硬编码(无Node侧provider切换)"
  - "P2:双轨LLM调用路径冗余(Node /api/llm/turn vs Pipecat LLM)"
  - "P3:alignDimensionScoresToTotal静默调整分数/无Docker/无CI/liveProviders.ts 1226行单文件"
business_scenarios: ["AI英语口语陪练", "面试口语训练", "场景化口语练习", "多维度量化评估(泛化)"]
reusable_assets:
  - "七维评分zod schema(shared/schemas.ts scoreDimensionSchema/reportResultSchema)"
  - "LLM输出归一化防御层(liveProviders.ts normalizeReportJson+normalize*系列)"
  - "mock/live双模式+缺Key回退模式(config.ts+liveProviders.ts)"
  - "reportDiagnostics多级兜底链(reportDiagnostics.ts)"
  - "Pipecat AssistantTurnPublisher自定义FrameProcessor(bot.py)"
  - "三段式可替换API链路预设体系(config.ts PRESETS)"
non_reusable_parts: ["App.tsx巨型组件结构", "内存会话存储(PracticeSessionStore Map)", "CORS *三服务手动部署架构"]
scores:
  product: 4
  architecture: 4
  engineering: 3
  reuse: 4
  commercialization: 3
evidence:
  - "README.md:3-5(产品定位+核心闭环)"
  - "README.md:27-36(题目需求覆盖)"
  - "README.md:65-72(技术栈+API模式)"
  - "README.md:80-96(API Provider方案+第三方能力说明)"
  - "README.md:221(密钥安全)"
  - "shared/schemas.ts:51-65(七维评分schema)"
  - "shared/schemas.ts:107-122(报告结果schema)"
  - "server/app.ts:53,64-67,73-99(CORS*+/api/settings无鉴权+session start)"
  - "server/config.ts:51-88,125-131,134,185-251(三预设+LLM Key别名+mock默认+运行时热切换)"
  - "server/practiceSession.ts:15,105-106(时长白名单+内存Map无持久化)"
  - "server/providers/liveProviders.ts:67-72,329-339,543-595,678-676(缺Key回退+parseJsonContent+clampScore/normalizeScoreScale/alignDimensionScoresToTotal+normalizeReportJson+normalize*系列)"
  - "server/providers/liveProviders.ts:302-311(Qwen ASR伪造时间戳)"
  - "server/providers/mockProviders.ts:21-87(mock全量)"
  - "src/App.tsx:93-120(1054行巨型组件状态机)"
  - "src/reportDiagnostics.ts:21-180(多级兜底链)"
  - "src/pipecatVoiceClient.ts:116-170,177-182(PipecatClient回调+disconnect清理)"
  - "pipecat_service/bot.py:43-71(system_instruction连续对话策略)"
  - "pipecat_service/bot.py:79-111(AssistantTurnPublisher自定义FrameProcessor)"
  - "pipecat_service/bot.py:131-158,176-201(AssemblyAI STT+OpenAI LLM+Cartesia TTS+IdleFrameProcessor+Pipeline)"
  - "tests/(16个测试文件,api.test.ts 439行/settings.test.ts 180行)"
confidence: "高"
```
