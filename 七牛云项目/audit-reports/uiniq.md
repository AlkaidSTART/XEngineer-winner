# uiniq 项目审查报告

> 审查日期: 2026-08-15
> 审查方法: qiniu-project-audit (6 步法)
> 证据纪律: 所有结论标注 [事实]/[推断]/[假设]，引用文件路径与行号

---

## 第 1 步: 确立项目边界

### 1.1 项目定位

uiniq 是一个 **语音优先的英语口语练习伴侣**，提供场景化对话练习、音素级发音评分、语法纠错、会话报告和长期进步追踪。荣获 ICCSE 2026 Agentic AI 创新竞赛银奖。

[事实] README.md: "A voice-first English speaking-practice companion"，银牌 ICCSE 2026。

### 1.2 目录结构

```
uiniq/
├── backend/                     FastAPI 服务
│   └── app/
│       ├── main.py              # 应用工厂 + lifespan (proactive引擎, weixin轮询, 迁移)
│       ├── session.py           # 共享Agent入口 (passive+active)
│       ├── config.py            # Pydantic Settings (prod验证)
│       ├── api/                 # chat(SSE) · voice(WS) · recordings · sessions ·
│       │                        # conversation · profile · live(/ws) · weixin · auth
│       ├── agent/               # 可复用harness: runner, tools, llm/
│       │   └── runner.py        # 无状态Agent循环 (LLM→tool_call→tool_result)
│       ├── skills/coach/        # 教练技能 (prompt + tools)
│       ├── integrations/        # asr · tts · pronunciation(SOE) · weixin · storage
│       ├── services/            # assessment · recording · learner · conversation_cache ·
│       │                        # weixin · sample_cache · feed · role · topic
│       ├── jobs/                # arq worker (assessment/nudge/feed/sample-reply)
│       ├── proactive/           # 主动引擎 (engine/bus/lock/policy)
│       ├── learner/             # 学习者模型
│       └── db/                  # models + Alembic迁移
├── frontend/                    Next.js 14 (App Router, TypeScript, Tailwind)
│   ├── app/(home)/              # / · /progress · /history · /settings + /practice/[topicId]
│   ├── components/uiniq/        # Talk(orb) · AssessmentBubble · SessionPanel · Onboarding
│   └── hooks/                   # useChat · useRecorder · useAssessment · useWs
├── docker-compose.yml           # 5服务 (backend/worker/frontend/postgres+pgvector/redis)
├── Makefile                     # 全套dev/ops命令
└── deploy/                      # nginx配置
```

### 1.3 边界确认

- **后端**: FastAPI, 分层 `api → services → repositories → db/models` [事实, README.md]
- **前端**: Next.js 14 App Router, TypeScript, Tailwind [事实, README.md]
- **数据库**: Postgres + pgvector (学习者模型、会话、录音、记忆嵌入) [事实, `docker-compose.yml`]
- **缓存/队列**: Redis (nudge bus · 会话恢复缓存 · sample-reply预热 · arq jobs) [事实, README.md]
- **AI**: 火山引擎 Doubao (Ark, OpenAI兼容流式function-calling) + Doubao Seed-TTS 2.0 + 流式/文件ASR [事实, `config.py:24-56`]
- **发音评测**: 腾讯智聆 SOE (WebSocket, 音素级) [事实, `integrations/pronunciation.py`]
- **存储**: 七牛云 Kodo (S3兼容) + 本地存储可切换 [事实, `config.py:118-126`]
- **微信**: iLink bot协议直连 (原生语音消息) [事实, README.md]

---

## 第 2 步: 还原产品/业务闭环

### 2.1 核心用户旅程

```
                    ┌─────────────────────────────────────┐
                    │         两条路径，一个大脑            │
                    │                                     │
  被动路径:          │  主动路径:                           │
  POST /api/chat ──┐│  proactive engine (后台ticker)      │
  (SSE流式)         ├┤  (定时轮询学习者profile)             │
                   ││                                     │
                   ▼▼                                     │
          app/session.run_agent_turn                      │
                   │                                      │
                   ▼                                      │
          agent harness (LLM + tools)                     │
                   │                                      │
          ┌────────┼────────┐                             │
          ▼        ▼        ▼                             │
     coach tools  发音评测  语法纠错                        │
     写入LearnerModel                                    │
          │                                             │
          ▼                                             │
  被动输出: SSE → 请求       主动输出: WebSocket /ws → 浏览器 │
                   │                                      │
                   ▼                                      │
          发音+语法评测 out-of-band                         │
          (arq worker → /ws推送)                          │
                    └─────────────────────────────────────┘
```

### 2.2 业务闭环分析

[事实] README.md "Two paths, one brain" 架构: 被动路径 (HTTP /api/chat SSE) 和主动路径 (proactive引擎) 共用 `run_agent_turn`，仅 prompt 来源和输出传输不同。

[事实] 完整口语练习闭环:
1. **场景选择** — interview/ordering/meeting/IELTS/daily + 自定义场景 [`db/models.py:180-196` Topic模型]
2. **实时语音** — 流式ASR (实时字幕) + 流式TTS; 点击orb说话, 点击打断
3. **发音评测** — 腾讯SOE音素级评分, 句内着色显示 [`integrations/pronunciation.py`]
4. **语法纠错** — Doubao在对话中+侧边栏结构化纠错
5. **会话报告** — pass/needs-practice, 能力雷达, 关键表达, 最弱句子回放
6. **进步追踪** — Progress页: 近期vs早期delta, 雷达图, 流利度曲线, 场景掌握度
7. **SRS循环** — 弱音素 + 频繁错误喂入SRS [`db/models.py:76-87` SRSState模型]
8. **主动陪伴** — 每日nudge + streak + 研究feed [`proactive/engine.py`]
9. **微信练习** — 绑定后发语音消息, 转写+回复+结构化反馈 [事实, README.md]

[推断] 这是5个项目中**产品完整度最高**的: 从实时对话到长期进步追踪, 从Web到微信, 从被动响应到主动陪伴, 形成了完整的口语学习闭环。

### 2.3 商业化潜力

[假设] 商业化路径明确: 订阅制 (月/年) + 按发音评测次数计费 + 企业版 (多角色/自定义场景)。银奖背书 + 微信入口降低了获客成本。

---

## 第 3 步: 还原技术架构

### 3.1 架构总览

```
┌─────────────────────────────────────────────────────────────┐
│  Frontend (Next.js 14, App Router)                          │
│  hooks: useChat · useRecorder · useAssessment · useWs       │
│  components: Talk(orb) · AssessmentBubble · SessionPanel    │
└────────┬──────────────────────────┬─────────────────────────┘
         │ SSE (/api/chat)           │ WS (/ws bus + /ws voice)
         ▼                           ▼
┌─────────────────────────────────────────────────────────────┐
│  Backend (FastAPI)                                          │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────────┐  │
│  │ Passive     │  │ Active       │  │ Voice (WS)        │  │
│  │ /api/chat   │  │ Proactive    │  │ ASR stream +      │  │
│  │ (SSE)       │  │ Engine       │  │ TTS stream        │  │
│  └──────┬──────┘  └──────┬───────┘  └────────┬──────────┘  │
│         │                │                   │              │
│         ▼                ▼                   │              │
│  ┌──────────────────────────────┐            │              │
│  │ session.run_agent_turn       │            │              │
│  │ (共享Agent入口)               │            │              │
│  └──────────┬───────────────────┘            │              │
│             ▼                                │              │
│  ┌──────────────────────────────┐            │              │
│  │ agent/runner.py              │            │              │
│  │ 无状态Agent循环               │            │              │
│  │ LLM stream → tool_call →     │            │              │
│  │ parallel tool exec → result  │            │              │
│  └──────────┬───────────────────┘            │              │
│             │                                │              │
│  ┌──────────┼──────────────────┐            │              │
│  ▼          ▼                  ▼            ▼              │
│ ┌────┐ ┌────────┐ ┌──────────┐ ┌──────────────┐           │
│ │LLM │ │Coach   │ │Pronuncia-│ │ integrations │           │
│ │Ark │ │Tools   │ │tion(SOE) │ │ asr/tts      │           │
│ └────┘ └────┬───┘ └──────────┘ └──────────────┘           │
│              │                                              │
│              ▼                                              │
│  ┌──────────────────────────────┐                          │
│  │ LearnerModel (PG+pgvector)   │                          │
│  │ learner/phoneme/grammar/     │                          │
│  │ srs/fluency/session/         │                          │
│  │ memory/recording/feed        │                          │
│  └──────────────────────────────┘                          │
└─────────────────────────────────────────────────────────────┘
         │                                │
         ▼                                ▼
┌─────────────────┐              ┌────────────────┐
│ arq Worker      │              │ Redis          │
│ (独立进程)       │              │ - nudge bus    │
│ - assessment    │              │ - 会话恢复缓存  │
│ - proactive     │              │ - sample预热   │
│   nudge         │              │ - arq jobs     │
│ - feed          │              │ - scheduler锁  │
│ - sample-reply  │              └────────────────┘
└─────────────────┘
```

### 3.2 关键技术决策

**[事实] "两条路径，一个大脑"架构** (`session.py:34-58`):
- `run_agent_turn()` 是被动和主动路径的共享入口
- 构建 `RunContext` (含 `ToolContext`, tools, llm_client, model, 配置)
- 压缩历史后驱动 `run_agent()`
- 主动路径 `generate_nudge()` 调用同一入口，LLM不可用时降级到 `build_opener()` 确定性opener

**[事实] 无状态Agent循环** (`agent/runner.py:33-186`):
- `run_agent()` 生成器驱动 LLM→tool_call→tool_result 循环
- 流式事件: `TextDelta` / `ToolCallStart` / `ToolCallDelta` / `LLMComplete`
- `_execute_tools_parallel()` 并行执行工具, 单工具时优化跳过gather
- `asyncio.wait_for` 每工具超时 (`tool_timeout_sec`)
- token budget 检查: 超预算停止工具循环
- `RunComplete` 带遥测 (iterations, tools, tokens in/out, 耗时)

**[事实] 历史压缩** (`session.py:79-126`):
- 保留最近8条消息原文
- 更早的消息折叠为system note
- 正则提取: `_extract_user_facts` (name/work/interests/location), `_extract_user_goals` (goal/difficulty/upcoming), `_extract_preferences` (request/preference/level signal), `_extract_open_threads` (coach提问/学习者未完成回答)
- 近重复检测 `_contains_near_duplicate`
- 最大1400字符截断

**[事实] 发音评测 (腾讯SOE)** (`integrations/pronunciation.py:1-273`):
- WSS连接 `wss://soe.cloud.tencent.com/soe/api/{appid}`
- HMAC-SHA1签名认证
- `rec_mode=1`: 一次性发送完整音频
- ffmpeg转码 PCM 16kHz mono
- eval_mode自适应: ≤30词用sentence, ≤120词用paragraph
- 音素级评分: per-word + per-phoneme + stress (参考vs检测)
- 解析容错: JSON → Go struct string fallback (`_parse_go_struct` 平衡括号匹配)
- `proxy=None` 强制直连 (绕过dev relay)
- **永不raise, 永不block**: 所有错误返回None

**[事实] 主动引擎** (`proactive/engine.py:1-90`):
- `ProactiveEngine` 后台asyncio.Task, 定时tick (`proactive_interval_sec`)
- scheduler锁 (`acquire_scheduler_lock`) 确保多实例只有一个执行
- `is_nudge_due()` + cooldown (`nudge_cooldown_sec`) 控制频率
- 优先通过arq job执行, job不可用则直接执行
- nudge通过bus publish → WebSocket推送到浏览器
- 同时生成feed

**[事实] arq异步任务** (`jobs/tasks.py:1-80`):
- `run_assessment`: 发音评测 (out-of-band, 推送到/ws)
- `generate_proactive_nudge`: 主动nudge
- `generate_feed`: feed生成
- `generate_sample_reply`: 预热"读这句"建议 (sample_cache)
- assessment有录音归属验证 (`learner_id` 匹配)

**[事实] 配置安全** (`config.py:136-185`):
- `validate_for_prod()`: prod环境启动时fail-fast检查
- 检查LLM_API_KEY, volcano凭证, CORS非通配, Redis URL等
- `_clean_volcano_value`: 过滤占位符 (`your-` 开头或 `#` 注释)

**[事实] 健康检查** (`main.py:96-129`):
- `/healthz`: 存活探针 (进程运行)
- `/readyz`: 就绪探针 (DB可达, 503 if not)
- Prometheus `/metrics`

**[事实] 数据模型** (`db/models.py:1-309`):
- 18个表: Learner, LearnerInterest, PhonemeStat, GrammarError, SRSState, FluencyPoint, SessionRecord, DailyCheckin, CustomTopic, Recording, AppUser, AuthSession, Topic, CoachRole, CompanionFeedItem, LearnerInsight, LearnerMemory(+pgvector), LearnerForgottenMemory, WeixinConnection
- pgvector: `LearnerMemory.embedding` (Vector(1024))
- 索引: 6个显式Index覆盖常用查询路径
- `WeixinConnection.bot_token` Fernet加密存储

### 3.3 Docker编排

[事实] `docker-compose.yml`: 5服务
- `backend`: uvicorn :8000, 依赖postgres+redis健康检查
- `worker`: arq worker (assessment/nudge/feed/sample-reply)
- `frontend`: Next.js :3000
- `postgres`: `pgvector/pgvector:pg16-trixie` (含pgvector扩展)
- `redis`: 标准Redis
- 全部有healthcheck, named volumes

---

## 第 4 步: 工程质量评分 (1-5)

| 维度 | 评分 | 理由 |
|------|------|------|
| 产品完整度 | 5 | 完整口语学习闭环: 实时对话+发音评测+语法纠错+报告+进步追踪+SRS+主动陪伴+微信入口 |
| 架构设计 | 5 | "两路径一大脑"设计优雅; 无状态Agent+并行工具+token预算; arq异步+Redis bus+scheduler锁; pgvector记忆 |
| 工程质量 | 4.5 | prod fail-fast配置验证, 健康检查, Prometheus, 结构化日志, X-Request-ID; CI/CD; Alembic迁移; 测试 |
| 可复用性 | 4.5 | Agent harness (runner+tools+llm) 高度可复用; session.py历史压缩模式; SOE评测封装; proactive引擎 |
| 商业化 | 4 | 银奖背书+微信入口+订阅+评测计费; 完整用户系统; 但缺支付/配额 |

**综合评分: 4.6/5**

### 4.1 关键工程亮点

**[事实] 生产硬化到位**:
- `ENV=prod` 启动时 `validate_for_prod()` fail-fast [`config.py:161-185`, `main.py:43-46`]
- 每个LLM/ASR/TTS调用有超时 + 指数退避重试 [`config.py:80-85`]
- 每工具超时 + 每轮token预算 [`runner.py:98-104, 160-163`]
- WSS强制直连 (`proxy=None`) 绕过dev relay [`pronunciation.py:85`]
- CORS非通配验证 [`config.py:175-176`]

**[事实] 可观测性完善**:
- 结构化日志 + X-Request-ID线程化 [`main.py:41`]
- Agent运行遥测 (iterations/tools/tokens/耗时) [`runner.py:128-135`]
- Prometheus `/metrics` [`main.py:102-108`]
- `RunComplete`事件带input/output tokens [`runner.py:136-141`]

**[事实] 可扩展性**:
- Redis nudge bus + arq jobs → API/worker/proactive可独立扩缩 [`README.md`]
- WS客户端按`learner_id`过滤 [`README.md`]
- scheduler锁确保多实例只有一个proactive [`engine.py:51-54`]

### 4.2 关键工程问题

**[推断] 中等: 历史压缩依赖正则** — `_extract_user_facts/goals/preferences` 使用正则匹配英文句式, 对非英语表达或复杂句式可能遗漏 [`session.py:129-158`]。但这是性能与准确性的合理权衡 (避免额外LLM调用)。

**[推断] 低: Go struct解析脆弱** — `_parse_go_struct` 依赖正则+括号匹配解析Go的 `%v` 输出, API格式变更可能失效 [`pronunciation.py:215-272`]。但已有JSON解析优先fallback。

**[假设] 低: 单learner默认** — `learner_id: str = "demo-user"` 默认值 [`config.py:70`], 但已有完整AppUser+AuthSession模型, 生产应通过auth覆盖。

---

## 第 5 步: 优缺点与可复用性评估

### 5.1 优点

1. **[事实] "两路径一大脑"架构优雅** — 被动和主动共用`run_agent_turn`, 仅prompt来源和输出传输不同, 消除代码重复 [`session.py:34-76`]
2. **[事实] 无状态Agent harness可复用** — `runner.py` 不依赖任何业务逻辑, 通过`RunContext`注入tools/llm/config, 可驱动任何LLM agent [`runner.py:33-186`]
3. **[事实] 并行工具执行 + token预算** — `asyncio.gather`并行, 单工具优化, `asyncio.wait_for`超时, token预算熔断 [`runner.py:98-176`]
4. **[事实] 历史压缩无需额外LLM** — 正则提取facts/goals/preferences/threads, 折叠为system note, 零额外token成本 [`session.py:79-220`]
5. **[事实] 发音评测永不阻塞** — 所有错误返回None, 对话永不被评测失败中断 [`pronunciation.py:50-57`]
6. **[事实] 主动引擎 + scheduler锁** — 多实例安全, cooldown控制, job优先+直接执行fallback [`engine.py:38-89`]
7. **[事实] 完整数据模型** — 18个表覆盖learner/phoneme/grammar/srs/fluency/session/memory/feed/weixin, pgvector记忆嵌入 [`db/models.py`]
8. **[事实] 生产配置fail-fast** — `validate_for_prod()` 在prod启动时检查所有必需配置 [`config.py:161-185`]
9. **[事实] sample-reply预热** — coach回复后异步预热"读这句"建议, 用户点击时即时返回 [`chat.py:61-63`, `tasks.py:70-79`]
10. **[事实] 微信原生语音** — iLink bot直连, Fernet加密bot_token, SILK转码 [事实, README + `db/models.py:284-302`]

### 5.2 缺点

1. **[推断] 历史压缩正则局限** — 英语句式依赖, 复杂表达可能遗漏
2. **[推断] Go struct解析脆弱** — 依赖腾讯API输出格式不变
3. **[假设] 缺支付/配额** — 商业化基础设施不完整
4. **[推断] 前端组件未深入审查** — hooks和components未逐一阅读, 前端质量评估基于README描述

### 5.3 可复用资产

| 资产 | 可复用性 | 说明 |
|------|----------|------|
| `agent/runner.py` 无状态Agent循环 | 极高 | LLM→tool→result循环+并行执行+token预算+遥测, 可驱动任何agent |
| `session.py` 历史压缩模式 | 极高 | 正则提取+折叠+近重复检测, 零LLM成本上下文管理 |
| `session.py` "两路径一大脑"模式 | 极高 | 被动+主动共用agent入口的架构模式 |
| `proactive/engine.py` 主动引擎 | 高 | 后台ticker+scheduler锁+cooldown+job优先, 可复用于任何主动推送场景 |
| `integrations/pronunciation.py` SOE评测 | 高 | 腾讯SOE WSS封装, 音素级解析, 永不阻塞 |
| `config.py` Pydantic Settings模式 | 高 | prod fail-fast验证 + 占位符过滤 + 环境分层 |
| `jobs/tasks.py` arq任务模式 | 高 | assessment/nudge/feed/sample-reply异步任务+归属验证 |
| `db/models.py` 学习者数据模型 | 高 | 18表完整学习者模型, 含pgvector记忆+SRS+fluency追踪 |
| `main.py` lifespan+健康检查模式 | 中高 | prod验证+proactive启动+weixin轮询+graceful shutdown+healthz/readyz |

### 5.4 不可复用部分

- 微信iLink集成 (与iLink协议强耦合)
- Coach skills prompt (业务特定)
- 前端orb UI组件 (未审查, 推测业务特定)

---

## 第 6 步: 提取学习内容

### 6.1 架构模式学习

**"两路径一大脑"模式**
```
被动路径 (用户发起)     主动路径 (系统发起)
     │                      │
     ▼                      ▼
  HTTP/SSE              background ticker
     │                      │
     └──────────┬───────────┘
                ▼
     shared_agent_entrypoint()
                │
                ▼
     agent_harness(llm, tools)
                │
        ┌───────┼───────┐
        ▼       ▼       ▼
     coach   write    nudge
     reply   learner  text
             model
```
- 学习点: 主动和被动交互共用agent入口, 消除重复, 统一行为

**无状态Agent循环 + 并行工具**
```
for iteration in max_iterations:
    llm_stream → collect text + tool_calls
    if no tool_calls: break
    if token_budget exhausted: break
    parallel execute tools (asyncio.gather, single-call optimized)
    append tool results to messages
yield RunComplete(telemetry)
```
- 学习点: 无状态设计使agent可测试、可复用; 并行工具+token预算是生产agent必需

**零LLM成本历史压缩**
```
history > 8 messages:
  recent 8 → verbatim
  older → regex extract (facts/goals/preferences/threads)
         → fold into system note (≤1400 chars)
         → near-duplicate dedup
```
- 学习点: 用正则替代LLM做上下文压缩, 在性能与准确性间取得平衡

**主动引擎 + scheduler锁**
```
while not stopped:
    acquire_scheduler_lock()  # 多实例只有一个执行
    for learner in all_learners:
        if is_nudge_due(profile) and past_cooldown:
            enqueue_proactive_job(learner)  # 优先异步
            # fallback: generate_nudge() + bus.publish()
    release_lock()
    sleep(interval)
```
- 学习点: 主动推送需要锁(多实例安全)+冷却(频率控制)+异步优先(不阻塞tick)

### 6.2 反模式学习

(本项目工程实践优秀, 反模式较少)

1. **[推断] 历史压缩正则的局限性** — 对非英语或复杂表达可能遗漏; 如果准确性要求高, 可考虑轻量LLM (如GPT-4o-mini) 做摘要, 但需权衡成本
2. **[推断] Go struct解析的脆弱性** — 依赖第三方API输出格式; 更稳健的方式是要求JSON格式或使用protobuf

### 6.3 可复用代码片段

**无状态Agent循环** (核心模式):
```python
async def run_agent(user_input, history, run_ctx):
    messages = [*history, {"role": "user", "content": user_input}]
    for _ in range(run_ctx.max_iterations):
        text_buf = ""
        pending = {}  # tool calls
        async for event in llm.stream(request):
            if isinstance(event, TextDelta): yield TextDelta(event.text)
            elif isinstance(event, ToolCallStart): pending[event.index] = {...}
            elif isinstance(event, ToolCallDelta): pending[event.index]["args"] += ...
        
        if finish_reason != "tool_calls": break
        if token_budget and tokens_used >= budget: break
        
        results = await _execute_tools_parallel(calls, run_ctx)
        for call in calls:
            yield ToolCompleted(...)
            messages.append({"role": "tool", "content": result.content})
    
    yield RunComplete(collected_text, tools_called, tokens)
```

**并行工具执行 + 超时**:
```python
async def _execute_tools_parallel(calls, run_ctx):
    async def _one(call):
        try:
            return call["id"], await asyncio.wait_for(
                tool.execute(args, ctx), timeout=run_ctx.tool_timeout_sec
            )
        except TimeoutError:
            return call["id"], ToolResult.error("timed out")
    
    if len(calls) == 1:  # 单工具优化
        cid, result = await _one(calls[0])
        return {cid: result}
    return dict(await asyncio.gather(*(_one(c) for c in calls)))
```

**prod配置fail-fast**:
```python
def validate_for_prod(self) -> list[str]:
    problems = []
    if not self.llm_api_key: problems.append("LLM_API_KEY empty")
    if "*" in self.cors_origins: problems.append("CORS wildcard unsafe")
    if self.bus_backend == "redis" and not self.redis_url: problems.append("REDIS_URL required")
    return problems

# lifespan中:
if s.env == "prod":
    problems = s.validate_for_prod()
    if problems:
        raise RuntimeError("invalid prod config: " + "; ".join(problems))
```

---

## YAML 摘要

```yaml
project: uiniq
one_line_judgment: 语音优先英语口语练习伴侣，银奖ICCSE2026，"两路径一大脑"架构+无状态Agent+pgvector记忆+主动引擎，5项目中工程化程度最高
product_type: AI英语口语练习伴侣 (语音对话+发音评测+语法纠错+进步追踪+主动陪伴+微信入口)
target_users: 英语口语学习者 (面试/日常/IELTS/商务场景练习)
core_loop: 选场景→实时语音对话→音素级发音评测+语法纠错→会话报告→SRS弱项追踪→主动nudge→进步追踪
architecture_style: FastAPI分层+Next.js 14; "两路径一大脑"(被动SSE+主动WS共用agent); 无状态Agent+并行工具+token预算; arq异步+Redis bus+scheduler锁; pgvector记忆
stack:
  - FastAPI (Python, 分层api→services→repositories→db)
  - Next.js 14 (App Router, TypeScript, Tailwind)
  - Postgres + pgvector (18表学习者模型+记忆嵌入)
  - Redis (nudge bus/会话缓存/sample预热/arq jobs/scheduler锁)
  - arq worker (assessment/nudge/feed/sample-reply)
  - 火山引擎 Doubao (Ark, OpenAI兼容流式function-calling, reasoning disabled)
  - Doubao Seed-TTS 2.0 + 流式/文件ASR
  - 腾讯智聆SOE (WSS, 音素级发音评测)
  - 七牛云Kodo (S3兼容存储)
  - Alembic (数据库迁移)
  - Docker Compose (5服务+healthchecks)
strongest_patterns:
  - "两路径一大脑" (被动SSE+主动WS共用run_agent_turn)
  - 无状态Agent循环 (LLM→tool→result, 并行执行, token预算, 遥测)
  - 零LLM成本历史压缩 (正则提取facts/goals/preferences/threads)
  - 主动引擎+scheduler锁+cooldown (多实例安全)
  - 发音评测永不阻塞 (所有错误返回None)
  - prod配置fail-fast (validate_for_prod)
  - sample-reply异步预热 (coach回复后预热"读这句")
  - pgvector学习者记忆 (1024维嵌入+分层+遗忘)
main_risks:
  - 低: 历史压缩正则对非英语/复杂表达可能遗漏 (性能权衡)
  - 低: Go struct解析依赖腾讯API格式不变 (有JSON fallback)
  - 低: 默认learner_id=demo-user (生产应auth覆盖)
  - 推断: 缺支付/配额基础设施
business_scenarios:
  - 面试英语模拟练习
  - 日常/点餐/会议场景对话
  - IELTS口语备考
  - 音素级发音纠正
  - 长期口语进步追踪
  - 微信原生语音练习
reusable_assets:
  - agent/runner.py无状态Agent循环 (极高)
  - session.py历史压缩模式 (极高)
  - "两路径一大脑"架构模式 (极高)
  - proactive/engine.py主动引擎 (高)
  - integrations/pronunciation.py SOE评测封装 (高)
  - config.py Pydantic Settings+prod验证模式 (高)
  - jobs/tasks.py arq任务模式 (高)
  - db/models.py学习者数据模型18表 (高)
  - main.py lifespan+健康检查模式 (中高)
non_reusable_parts:
  - 微信iLink集成 (协议强耦合)
  - Coach skills prompt (业务特定)
  - 前端orb UI组件 (推测业务特定)
scores:
  product: 5
  architecture: 5
  engineering: 4.5
  reuse: 4.5
  commercialization: 4
evidence:
  - "[事实] 银奖ICCSE 2026: README.md"
  - "[事实] 两路径一大脑: session.py:34-76 (run_agent_turn共享入口)"
  - "[事实] 无状态Agent循环: runner.py:33-186 (LLM→tool→result+并行+token预算)"
  - "[事实] 并行工具执行: runner.py:148-176 (asyncio.gather+单工具优化+wait_for超时)"
  - "[事实] 历史压缩: session.py:79-220 (8条verbatim+正则提取+1400字符截断)"
  - "[事实] 发音评测永不阻塞: pronunciation.py:50-57 (所有错误返回None)"
  - "[事实] SOE音素级: pronunciation.py:190-212 (per-word+per-phoneme+stress)"
  - "[事实] 主动引擎+锁: engine.py:38-89 (scheduler锁+cooldown+job优先)"
  - "[事实] arq任务: tasks.py:1-80 (assessment/nudge/feed/sample-reply+归属验证)"
  - "[事实] prod fail-fast: config.py:161-185 + main.py:43-46"
  - "[事实] 18表数据模型: db/models.py:1-309 (含pgvector记忆+SRS+fluency)"
  - "[事实] 5服务Docker: docker-compose.yml (backend/worker/frontend/pgvector/redis+healthcheck)"
  - "[事实] 健康检查: main.py:96-129 (healthz+readyz+metrics)"
  - "[事实] sample-reply预热: chat.py:61-63 + tasks.py:70-79"
  - "[事实] 微信Fernet加密: db/models.py:284-302 (WeixinConnection.bot_token)"
  - "[推断] 历史压缩正则对非英语可能遗漏"
  - "[推断] Go struct解析脆弱 (有JSON fallback)"
  - "[假设] 缺支付/配额基础设施"
confidence: high
```
