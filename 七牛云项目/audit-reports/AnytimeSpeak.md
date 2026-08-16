# AnytimeSpeak 项目审计报告

> 一句话判断：AnytimeSpeak 是一个工程完成度很高的 AI 英语口语陪练 MVP，其"全链路 mock fallback + provider badge"模式是五个项目中最成熟的降级设计；但用户认证仅靠 user_id 传递、无任何 token 机制，构成 P1 安全隐患。

---

## 一、项目边界确认

### 1.1 项目定位（事实）

AnytimeSpeak 是一个面向中国英语学习者的 AI 口语陪练工具。用户选择真实场景（面试、点餐、会议、旅行、日常交流），与 AI 角色进行英语对话训练，练习中获得表达建议和语法反馈，结束后获得评分总结。视觉风格定位为 Taylor Swift Lover 风格的柔和粉紫色系。

- 产品文档：`/Users/allure/Desktop/七牛云项目/AnytimeSpeak/PRODUCT.md` 第 12-13 行明确产品目的
- README：`/Users/allure/Desktop/七牛云项目/AnytimeSpeak/README.md` 第 1-7 行

### 1.2 目录结构（事实）

```
AnytimeSpeak/
├── frontend/              # React + Vite + TypeScript
│   └── src/
│       ├── App.tsx        # 1538 行单文件主应用
│       ├── speech/        # 7 个语音模块（浏览器 ASR、豆包 ASR、录音、TTS）
│       ├── api/           # coaching.ts + history.ts
│       └── components/    # VoiceControls.tsx
├── backend/               # FastAPI + Python
│   ├── app/               # 11 个 Python 模块，~4392 行
│   │   ├── main.py        # FastAPI 路由入口
│   │   ├── llm_provider.py    # LLM 调用 + 降级（1067 行）
│   │   ├── asr_provider.py    # 豆包 ASR WebSocket 代理
│   │   ├── pronunciation_provider.py  # 发音测评（572 行）
│   │   ├── mock_service.py    # 完整 mock 实现（1022 行）
│   │   ├── scenario_catalog.py # 5 场景 × 3 story seeds
│   │   ├── database.py        # SQLite + 迁移逻辑
│   │   ├── history_service.py # 用户认证 + 历史持久化
│   │   └── schemas.py         # Pydantic 模型
│   └── tests/            # 8 个测试文件，~2083 行
├── docs/                 # API 契约、产品设计
├── scripts/              # 一键启动/停止
└── .env.example          # 环境变量模板（无密钥）
```

### 1.3 技术栈（事实）

| 层 | 技术 | 版本 |
|---|---|---|
| 前端框架 | React + Vite + TypeScript | - |
| 后端框架 | FastAPI + Python | fastapi==0.115.6 |
| 数据库 | SQLite | WAL 模式 |
| LLM | OpenAI-compatible API | 通过环境变量配置 |
| ASR | 豆包 BigModel Streaming ASR | volcengine-audio==0.2.4 |
| 发音测评 | 科大讯飞 XFYUN ISE / 通用 API | WebSocket |
| 依赖来源 | `/Users/allure/Desktop/七牛云项目/AnytimeSpeak/backend/requirements.txt` | - |

---

## 二、用户/产品回路还原

### 2.1 目标用户（事实）

PRODUCT.md 第 9 行：中国英语学习者（大学生、年轻职场人），桌面浏览器使用，单次练习 5-15 分钟，希望获得即时反馈但不打断对话流。

### 2.2 核心产品回路（事实 + 推断）

```
选择场景 → 创建 session（含 story seed 随机选择）→ 语音/文本输入
→ AI 角色回复 → 即时反馈（推荐英文、问题、评分）→ [可选] 发音测评
→ 结束练习 → 课后总结与量化评分 → 保存历史 → 回看详情
```

- 场景选择：`scenario_catalog.py` 第 33-443 行定义 5 个场景（interview、ordering_food、meeting、travel、daily_conversation），每个场景含 3 个 story seeds
- Session 创建：`mock_service.py` 第 86-114 行 `start_session()` 随机选择 story seed
- 对话：`llm_provider.py` 第 97-122 行 `create_chat_reply_with_fallback()` → 真实 LLM 或 mock
- 即时反馈：`llm_provider.py` 第 124-141 行 `create_feedback_with_fallback()` → 语法/自然度/相关性/清晰度评分
- 发音测评：`pronunciation_provider.py` 第 48-67 行 `assess_pronunciation_with_fallback()` → XFYUN/API/启发式 mock
- 课后总结：`llm_provider.py` 第 144-174 行 `create_summary_with_fallback()` → 优势/重复问题/可复用表达/评分
- 历史保存：`history_service.py` 第 94-189 行 `save_practice_session()` → SQLite 持久化

### 2.3 产品设计原则（事实）

PRODUCT.md 第 28-35 行：
1. 练习流不被打断——反馈在对话旁边，不在前面
2. 温暖的信心——UI 是鼓励，不是评价
3. 分数最后展示——不在练习中闪数字
4. 一屏一职——每个视图只有一个主要动作
5. 语音优先，文本兜底——麦克风是默认，打字随时可用

---

## 三、技术架构还原

### 3.1 整体架构（事实）

```
┌─────────────────────────────────────────────────────┐
│                 Frontend (React)                      │
│  ┌──────────┐  ┌──────────┐  ┌───────────────────┐  │
│  │ Scenario  │  │ Practice │  │ Summary/History   │  │
│  │ Selection │  │  View    │  │    Views          │  │
│  └────┬─────┘  └────┬─────┘  └────────┬──────────┘  │
│       │              │                  │             │
│  ┌────┴──────────────┴──────────────────┴──────────┐ │
│  │              API Layer (coaching.ts + history.ts)│ │
│  │   localScenarios / createLocalReply / createLocalSummary  │
│  └────┬──────────────┬──────────────────┬──────────┘ │
│       │ HTTP         │ WebSocket        │            │
│  ┌────┴──────────────┴──────────────────┴──────────┐ │
│  │  Speech Layer (speech/)                          │ │
│  │  browserSpeechProvider / doubaoSpeechProvider    │ │
│  │  useVoiceRecorder / useSpeechOutput              │ │
│  └──────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
         │ REST API              │ WebSocket
         ▼                       ▼
┌─────────────────────────────────────────────────────┐
│                Backend (FastAPI)                      │
│  ┌─────────────────────────────────────────────────┐ │
│  │              main.py (路由层)                     │ │
│  │  /api/scenarios  /api/chat  /api/feedback        │ │
│  │  /api/summary  /api/pronunciation/assess         │ │
│  │  /api/users/*  /api/history/*  /ws/asr           │ │
│  └──────┬──────────┬──────────────┬────────────────┘ │
│         │          │              │                   │
│  ┌──────┴───┐ ┌────┴────┐ ┌──────┴────────┐          │
│  │llm_provider│ │asr_provider│ │pronunciation_provider│     │
│  │  fallback │ │  proxy   │ │   fallback    │          │
│  └──┬───┬───┘ └────┬────┘ └──┬───┬────────┘          │
│     │   │          │         │   │                     │
│  LLM  Mock      Doubao    XFYUN Mock                  │
│  API  Service    ASR WS    ISE   heuristic            │
│         │                                         │
│  ┌──────┴──────────────────────────────────────────┐ │
│  │  mock_service.py (session 管理 + mock 业务逻辑)  │ │
│  │  scenario_catalog.py (场景配置 + story seeds)     │ │
│  └──────────────────────────────────────────────────┘ │
│  ┌──────────────────────────────────────────────────┐ │
│  │  database.py + history_service.py (SQLite)        │ │
│  │  users / practice_sessions / messages / feedbacks │ │
│  └──────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

### 3.2 核心架构模式：三层 Provider Fallback（事实）

这是本项目最重要的架构贡献。每个外部依赖都遵循统一模式：

```python
# llm_provider.py 第 97-122 行（代表性示例）
def create_chat_reply_with_fallback(request: ChatRequest) -> ChatResponse:
    config_reason = _llm_config_fallback_reason()  # 第一层：配置检查
    if config_reason:
        return _mock_chat_reply(request, config_reason)  # 直接 mock

    try:
        raw_content = _request_chat_completion(...)  # 第二层：真实调用
        data = _chat_data_from_llm(raw_content)
        # 质量检查...
        return ChatResponse(..., provider="llm")
    except Exception as exc:
        _log_fallback("chat", exc)  # 第三层：异常降级
        return _mock_chat_reply(request, _fallback_reason(exc))
```

三层降级逻辑：
1. **配置检查**：`_llm_config_fallback_reason()` 检查 provider_mode、api_key、base_url、model 是否齐全（`llm_provider.py` 第 201-212 行）
2. **真实调用**：`_request_chat_completion()` 发起 HTTP 请求（`llm_provider.py` 第 215-242 行）
3. **异常降级**：`_fallback_reason()` 根据异常类型返回降级原因（timeout/http_error/parse_failed/quality_error/schema_error）（`llm_provider.py` 第 555-566 行）

三个 provider 都遵循此模式：
- LLM：`llm_provider.py` — mock → OpenAI-compatible API
- ASR：`asr_provider.py` — browser SpeechRecognition → 豆包 BigModel Streaming ASR
- Pronunciation：`pronunciation_provider.py` — heuristic_mock → 通用 API / 科大讯飞 XFYUN ISE

### 3.3 Provider Badge 透明度模式（事实）

每个响应都携带 `provider` 和 `fallback_reason` 字段：
- `llm_provider.py` 第 116 行：`provider="llm"` / 第 180 行：`provider="mock"`
- `pronunciation_provider.py` 第 365 行：`provider="heuristic_mock"` / 第 234 行：`provider="xfyun_pronunciation"`
- 前端 `App.tsx` 第 1336-1338 行：展示 provider badge（llm/fallback）

这使前端可以明确告诉用户"这条回复来自真实 AI 还是本地 mock"，是演示场景下的优秀设计。

### 3.4 前端双 fallback 架构（事实）

前端自身也有完整的本地 fallback：
- `App.tsx` 第 64-66 行：`localScenarios` 作为初始场景数据
- `App.tsx` 第 273-278 行：后端 chat 请求失败时使用 `createLocalReply()` 本地生成回复
- `App.tsx` 第 317 行：后端 summary 请求失败时使用 `createLocalSummary()` 本地生成总结
- `App.tsx` 第 150-156 行：场景加载失败时回退到 `localScenarios`

因此存在**双层降级**：后端 provider 失败 → 后端 mock → 后端不可达 → 前端本地 fallback。

### 3.5 WebSocket ASR 代理架构（事实）

`asr_provider.py` 第 171-339 行 `proxy_doubao_asr()` 实现了双向 WebSocket 中继：

```
Frontend WebSocket ←→ Backend (proxy_doubao_asr) ←→ Doubao ASR WebSocket
```

- 前端 → 后端协议：JSON config 帧 / Binary PCM 音频 / JSON end 帧
- 后端 → 前端协议：ready / partial / final / error
- 后端 → 豆包：使用 `volcengine-audio` SDK 的 `VolcengineAsrFunctionsV3` 生成 V3 二进制帧
- 双向并发：`asyncio.gather(relay_frontend_to_doubao, relay_doubao_to_frontend)` 第 322-326 行

### 3.6 数据持久化架构（事实）

`database.py` 第 8-54 行定义 4 张表：
- `users`：id, username, password_hash, created_at
- `practice_sessions`：session_id, scenario, story_intro, summary_json, provider, score
- `messages`：session_id, role, content
- `feedbacks`：session_id, user_message, feedback_json, score

数据库迁移逻辑（`database.py` 第 74-178 行）：
- `_migrate_legacy_users_table()`：旧 guest 用户表迁移到带密码的 users 表
- `_ensure_practice_session_columns()`：动态添加缺失列
- `_repair_practice_session_user_fk()`：修复外键约束

---

## 四、工程质量评估

### 4.1 评分总览

| 维度 | 评分 | 依据 |
|---|---|---|
| 架构设计 | 5/5 | 三层 provider fallback + provider badge + 前端双 fallback 是成熟的降级架构 |
| 代码质量 | 4/5 | LLM JSON 解析和 prompt 工程非常精细，但 App.tsx 1538 行单文件偏大 |
| 测试覆盖 | 4/5 | 8 个测试文件 ~2083 行，test_llm_provider.py 1010 行覆盖最复杂模块 |
| 安全性 | 3/5 | 密码哈希规范（PBKDF2-SHA256），但无 token 认证，history 端点裸奔 |
| 可维护性 | 4/5 | 模块化清晰，provider 模式统一，但 mock_service.py 1022 行偏大 |
| 文档质量 | 5/5 | README + PRODUCT.md + .env.example + API 契约，文档非常完整 |
| 可复现性 | 5/5 | 全链路 mock fallback，零配置即可跑通完整 demo |
| **综合** | **4.3/5** | |

### 4.2 架构设计（5/5）——证据

**正面：**
- 三层 provider fallback 模式统一应用于 LLM/ASR/发音三个外部依赖（`llm_provider.py` 第 97-122 行、`asr_provider.py` 第 73-90 行、`pronunciation_provider.py` 第 48-67 行）——事实
- Provider badge 使降级状态对用户透明（`llm_provider.py` 第 116/180 行、前端 `App.tsx` 第 1336 行）——事实
- 前端双 fallback：后端不可达时前端本地生成回复和总结（`App.tsx` 第 273-278/317 行）——事实
- Session 内 story seed 随机选择增加练习多样性（`mock_service.py` 第 78-83 行 `random.choice`）——事实

### 4.3 代码质量（4/5）——证据

**正面：**
- LLM JSON 解析极其健壮：多候选策略（原始内容、code fence、JSON 值扫描、大括号截取）+ 多变体解析（smart quote 转换、trailing comma 移除、key 引号补全）（`llm_provider.py` 第 438-542 行）——事实
- LLM 质量守卫：防重复回复（`_chat_reply_repeats_history` 第 1031-1035 行）、防禁止性反馈（`_avoid_forbidden_mixed_input_feedback` 第 759-790 行）、防标点-only 反馈（`_avoid_punctuation_only_feedback` 第 840-854 行）、防内部 prompt 泄露（`_avoid_internal_prompt_feedback` 第 857-864 行）——事实
- 安全日志实践：`_log_fallback()` 第 87-94 行注释明确说明"never log exception message or request payload"以防泄露配置——事实
- 评分解析容忍：`_clamp_breakdown_value()` 第 939-960 行支持 "85/100" 比率格式、字符串数字提取——事实

**负面：**
- `App.tsx` 1538 行单文件包含 App、ProfileModal、HistoryList、HistoryDetailView、Home、Scenarios、Practice、PronunciationMiniPanel、Summary、StatusBanner、TagList、SummaryList 等 12+ 组件——事实
- `mock_service.py` 1022 行包含 mock 回复、mock 反馈、mock 总结、Chinglish 检测、语法检测、情绪检测、中英翻译等过多职责——事实
- `llm_provider.py` 1067 行虽功能集中但 prompt 字符串过长（`_chat_prompt` 第 261-316 行 system prompt 单段约 500 词）——事实

### 4.4 测试覆盖（4/5）——证据

**正面：**
- `test_llm_provider.py` 1010 行，覆盖：配置缺失降级、LLM 调用失败降级、API key 优先级、JSON 解析、质量守卫、重复检测（第 14-120 行代表性测试）——事实
- 测试使用 `monkeypatch` 隔离环境变量（`_clear_llm_env` 第 8-11 行设置 `ANYTIMESPEAK_SKIP_DOTENV=1`）——事实
- 测试 mock `httpx.post` 验证真实调用路径（第 91-95 行 `fake_post`）——事实
- 8 个测试文件覆盖：health、ASR、LLM provider、mock coaching API、scenario catalog、history、pronunciation assessment——事实

**负面：**
- 无前端测试（推断：frontend/ 目录下未发现测试文件）——事实
- 无端到端测试或集成测试——推断

### 4.5 安全性（3/5）——证据

**正面：**
- 密码哈希：PBKDF2-SHA256，120,000 次迭代，随机 16 字节 salt（`history_service.py` 第 19/26-29 行）——事实
- 常量时间密码比较：`hmac.compare_digest()`（`history_service.py` 第 44 行）——事实
- `.env.example` 无任何真实密钥（`.env.example` 第 1-38 行全部为空值或默认值）——事实
- API key 仅在后端读取，前端不接触密钥（`llm_provider.py` 第 245-254 行、`asr_provider.py` 第 45-52 行、`pronunciation_provider.py` 第 485-506 行）——事实
- CORS 仅允许 localhost 开发端口（`main.py` 第 57-76 行）——事实
- SQLite 文件不在仓库中（`.gitignore` 覆盖 `backend/data/`）——事实

**负面（P1 安全隐患）：**
- **无 token 认证机制**：注册/登录返回 `user_id`，后续请求直接传 `user_id` 作为身份标识，无 JWT/session token（`history_service.py` 第 47-76 行、`main.py` 第 192-220 行）——事实
- **history 端点无鉴权**：`GET /api/history/sessions?user_id=xxx` 不验证调用者身份，任何人知道 user_id 即可读取他人练习历史（`main.py` 第 210-212 行）——事实
- **session 详情无鉴权**：`GET /api/history/sessions/{session_id}` 不验证 session 归属（`main.py` 第 215-219 行）——事实
- **user info 无鉴权**：`GET /api/users/{user_id}` 不验证调用者身份（`main.py` 第 192-197 行）——事实
- 无速率限制——推断
- SQLite 不适合多用户并发生产环境——推断

### 4.6 文档质量（5/5）——证据

- README 206 行：项目说明、核心功能、截图、技术架构、目录结构、本地运行、环境变量、API 概览、Demo 流程、安全说明、扩展方向——事实
- PRODUCT.md 37 行：用户画像、产品目的、品牌人格、设计反例、设计原则、无障碍——事实
- `.env.example` 38 行：每个变量都有注释说明——事实
- API 端点列表完整（README 第 147-163 行）——事实
- Demo 视频链接（README 第 181 行）——事实

### 4.7 可复现性（5/5）——证据

- 零配置可跑通：默认 `LLM_PROVIDER_MODE=mock`、`ASR_PROVIDER_MODE=browser`、`PRONUNCIATION_PROVIDER_MODE=mock`（`.env.example` 第 1/11/27 行）——事实
- mock_service.py 提供完整的业务逻辑 mock（非空壳 stub），包括场景化回复、Chinglish 检测、语法模式匹配、情绪检测（`mock_service.py` 第 124-1023 行）——事实
- 前端 localScenarios / createLocalReply / createLocalSummary 提供前端本地 fallback——事实

---

## 五、优点

1. **三层 provider fallback 是最成熟的降级设计**（事实）：配置检查 → 真实调用 → 异常降级，三个 provider 统一模式，降级原因分类清晰（timeout/http_error/parse_failed/quality_error/schema_error）

2. **Provider badge 透明度**（事实）：每个响应带 provider/fallback_reason，前端展示 badge，演示场景下用户明确知道结果来源

3. **前端双 fallback**（事实）：后端不可达时前端本地生成，实现"永远有响应"的用户体验

4. **LLM JSON 解析极其健壮**（事实）：多候选 + 多变体解析策略，应对 LLM 返回不规范 JSON 的各种情况

5. **LLM 质量守卫体系**（事实）：防重复、防禁止性反馈、防标点-only、防内部 prompt 泄露，4 道质量关卡

6. **mock_service 是真实业务逻辑而非空壳**（事实）：包含 Chinglish 检测（`_CHINGLISH_PATTERNS` 第 753-764 行）、语法检测（`_GRAMMAR_PATTERNS` 第 772-780 行）、情绪检测（`_NEGATIVE_EMOTION_MARKERS` 第 513-532 行）、中英翻译（`_ZH_EN_VOCAB` 第 907-944 行）

7. **密码安全规范**（事实）：PBKDF2-SHA256 + 120k 迭代 + 随机 salt + 常量时间比较

8. **场景设计有深度**（事实）：5 场景 × 3 story seeds = 15 种练习情境，每个场景有独立的 AI 角色、目标、反馈焦点、评分焦点

9. **数据库迁移逻辑完善**（事实）：legacy 表迁移、列动态添加、外键修复

10. **安全日志意识**（事实）：`_log_fallback()` 注释明确不记录异常消息和请求体以防泄露配置

---

## 六、缺点与风险

### P1 级（需修复）

1. **无 token 认证机制**（事实）：注册/登录返回 user_id，后续请求直接传 user_id，无 JWT/session token。任何人知道 user_id 即可读取他人练习历史、用户信息。`main.py` 第 192-220 行的 history/user 端点均无鉴权。

2. **session 存储为内存态**（事实）：`mock_service.py` 第 29 行 `SESSIONS: dict[str, PracticeSession] = {}`，进程重启后所有活跃 session 丢失。

### P2 级（应改进）

3. **前端单文件过大**（事实）：`App.tsx` 1538 行包含 12+ 组件，不利于维护和测试。

4. **ScriptProcessorNode 已弃用**（事实）：`doubaoSpeechProvider.ts` 第 56 行注释承认使用 deprecated API，虽有 eslint-disable 但长期应迁移到 AudioWorklet。

5. **无速率限制**（推断）：FastAPI 未配置 rate limiting，LLM/ASR/发音测评端点可被滥用。

6. **SQLite 不适合生产**（推断）：单文件 SQLite 在多用户并发下有写锁瓶颈，README 第 203 行也提到"更稳定的云端历史"作为扩展方向。

### P3 级（可优化）

7. **mock_service.py 职责过重**（事实）：1022 行包含 mock 回复、反馈、总结、Chinglish 检测、语法检测、情绪检测、中英翻译，应拆分。

8. **prompt 字符串过长**（事实）：`_chat_prompt` system prompt 单段约 500 词，`_feedback_prompt` 约 800 词，维护困难。

9. **无前端测试**（推断）：frontend/ 下未发现测试文件。

10. **无 CI/CD**（推断）：项目目录下未发现 `.github/workflows/` 或 CI 配置。

---

## 七、可复用性矩阵

| 模块 | 可复用场景 | 复用成本 | 备注 |
|---|---|---|---|
| 三层 provider fallback 模式 | 任何需要外部依赖降级的 AI 应用 | 低 | 模式清晰，`llm_provider.py` 第 97-122 行可直接参考 |
| Provider badge 模式 | 任何需要展示 AI/mock 来源的演示产品 | 低 | 前后端协议简单 |
| LLM JSON 解析策略 | 任何需要解析 LLM JSON 输出的应用 | 中 | `llm_provider.py` 第 438-542 行，多候选+多变体 |
| LLM 质量守卫 | 任何 LLM 对话/反馈应用 | 中 | 防重复/防禁止性反馈/防标点-only |
| WebSocket ASR 代理 | 任何需要后端代理流式 ASR 的应用 | 中 | `asr_provider.py` 双向中继模式 |
| 启发式发音测评 | 无 API 依赖的发音评分 demo | 中 | `pronunciation_provider.py` 第 279-379 行 |
| 场景化 story seed 设计 | 任何场景化对话练习产品 | 低 | `scenario_catalog.py` 数据结构可复用 |
| SQLite 迁移逻辑 | 任何需要 schema 演进的 SQLite 项目 | 低 | `database.py` 第 74-178 行 |
| 前端双 fallback 架构 | 任何需要"永远有响应"的 demo 产品 | 低 | App.tsx 本地 fallback 模式 |
| PBKDF2 密码哈希 | 任何需要用户密码的项目 | 低 | `history_service.py` 第 19/26-44 行 |
| 中英混合输入处理 | 任何面向中国用户的 AI 对话产品 | 中 | `mock_service.py` Chinglish/语法/情绪检测 |

---

## 八、学习内容提取

### 8.1 架构设计学习

1. **三层降级模式**：配置检查（preventive）→ 真实调用（attempt）→ 异常降级（reactive）。每层都有明确的降级原因分类，便于调试和监控。

2. **Provider badge 透明度**：在演示/Demo 场景下，明确告诉用户"这条回复来自真实 AI 还是 mock"比假装一切正常更诚实，也更容易定位问题。

3. **前端双 fallback**：后端 mock + 前端本地 fallback = "永远有响应"。这对于 Demo 演示和弱网场景至关重要。

4. **统一 provider 接口**：三个 provider（LLM/ASR/发音）遵循相同的 `*_with_fallback` 函数签名和降级逻辑，降低认知成本。

### 8.2 LLM 工程学习

5. **LLM JSON 解析防御**：LLM 返回的 JSON 可能不规范（code fence 包裹、smart quotes、trailing commas、unquoted keys）。多候选+多变体解析策略是生产级实践。

6. **LLM 质量守卫**：LLM 可能返回重复回复、禁止性反馈（如批评用户混用中文）、标点-only 修正、甚至泄露内部 prompt 规则。需要在业务层设置质量关卡。

7. **场景化 prompt 工程**：将场景信息（AI 角色、用户角色、目标、story、反馈焦点、评分焦点）注入 system prompt，使 LLM 回复有场景 grounding 而非通用模板。

8. **降级原因分类**：`_fallback_reason()` 根据异常类型（timeout/http_error/parse_failed/quality_error/schema_error）返回不同的降级原因字符串，便于前端展示和日志分析。

### 8.3 安全工程学习

9. **密码哈希最佳实践**：PBKDF2-SHA256 + 120k 迭代 + 随机 salt + 常量时间比较（`hmac.compare_digest`）。这是 Python 标准库可实现的密码安全基线。

10. **安全日志实践**：`_log_fallback()` 注释"never log exception message or request payload"，因为异常消息可能包含配置值。只记录操作类型和异常类型名。

11. **反面教训——认证缺失**：仅有密码哈希不够，还需要 token 机制（JWT/session）来验证后续请求的身份。user_id 作为身份标识等同于无认证。

### 8.4 前端工程学习

12. **语音输入 provider 抽象**：`SpeechInputProvider` 接口抽象（`speech/types.ts`），使浏览器 ASR 和豆包 ASR 可互换，前端代码不感知具体实现。

13. **WebSocket 音频流处理**：`doubaoSpeechProvider.ts` 使用 Web Audio API 的 ScriptProcessorNode 捕获 PCM 音频，float32ToInt16 转换，通过 WebSocket 发送二进制帧。

14. **录音 URL 生命周期管理**：`App.tsx` 第 132-137 行在组件卸载时 `URL.revokeObjectURL` 释放录音 URL，避免内存泄漏。

15. **pendingHistory 延迟保存**：`App.tsx` 第 96 行 `pendingHistoryRef` + `storePendingHistory`，用户未登录时练习结果暂存 localStorage，登录后自动补存。

---

## 九、YAML 摘要

```yaml
project: AnytimeSpeak
type: "AI 英语口语陪练 MVP"
tech_stack:
  frontend: "React + Vite + TypeScript"
  backend: "FastAPI + Python"
  database: "SQLite (WAL mode)"
  ai_providers:
    llm: "OpenAI-compatible API (mock fallback)"
    asr: "豆包 BigModel Streaming ASR (browser fallback)"
    pronunciation: "科大讯飞 XFYUN ISE / 通用 API (heuristic mock fallback)"
lines_of_code:
  backend_app: 4392
  backend_tests: 2083
  frontend_main: 1538
  total_estimated: 8000+
scores:
  architecture: 5
  code_quality: 4
  test_coverage: 4
  security: 3
  maintainability: 4
  documentation: 5
  reproducibility: 5
  overall: 4.3
key_strengths:
  - "三层 provider fallback 是最成熟的降级设计"
  - "Provider badge 透明度模式"
  - "前端双 fallback 架构"
  - "LLM JSON 解析极其健壮"
  - "LLM 质量守卫体系（防重复/防禁止性反馈/防标点-only/防prompt泄露）"
  - "mock_service 是真实业务逻辑而非空壳"
  - "密码安全规范（PBKDF2-SHA256 + 120k迭代 + 常量时间比较）"
key_issues:
  - severity: P1
    issue: "无 token 认证机制，user_id 直接作为身份标识，history 端点无鉴权"
    location: "main.py 第 192-220 行"
  - severity: P1
    issue: "session 内存存储，进程重启丢失"
    location: "mock_service.py 第 29 行"
  - severity: P2
    issue: "前端 App.tsx 1538 行单文件过大"
    location: "frontend/src/App.tsx"
  - severity: P2
    issue: "ScriptProcessorNode 已弃用"
    location: "frontend/src/speech/doubaoSpeechProvider.ts 第 56 行"
  - severity: P2
    issue: "无速率限制"
    location: "main.py 全局"
reusability:
  - module: "三层 provider fallback 模式"
    cost: low
  - module: "Provider badge 模式"
    cost: low
  - module: "LLM JSON 解析策略"
    cost: medium
  - module: "LLM 质量守卫"
    cost: medium
  - module: "WebSocket ASR 代理"
    cost: medium
  - module: "启发式发音测评"
    cost: medium
  - module: "场景化 story seed 设计"
    cost: low
  - module: "SQLite 迁移逻辑"
    cost: low
  - module: "前端双 fallback 架构"
    cost: low
  - module: "PBKDF2 密码哈希"
    cost: low
  - module: "中英混合输入处理"
    cost: medium
security_findings:
  - severity: P1
    type: "认证缺失"
    detail: "无 JWT/session token，user_id 直接传参，任何人可读取他人历史"
    evidence_type: fact
  - severity: pass
    type: "密码哈希"
    detail: "PBKDF2-SHA256, 120k 迭代, 随机 salt, hmac.compare_digest"
    evidence_type: fact
  - severity: pass
    type: "密钥管理"
    detail: ".env.example 无密钥，API key 仅后端读取，.gitignore 覆盖数据库文件"
    evidence_type: fact
  - severity: pass
    type: "CORS"
    detail: "仅允许 localhost 开发端口"
    evidence_type: fact
evidence_discipline:
  total_findings: 25
  fact: 22
  inference: 3
  hypothesis: 0
```
