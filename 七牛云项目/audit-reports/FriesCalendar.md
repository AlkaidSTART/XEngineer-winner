# FriesCalendar（薯条日历）项目审查报告

## 一句话判断

FriesCalendar 是一个完成度较高的语音日历助手，前后端分工清晰、安全意识到位（Keychain/bcrypt/JWT/后端代理 API Key），核心创新在于"LLM 两阶段决策（先判断是否读日历，再生成结构化计划）+ 用户确认后才写 EventKit"的人机协同闭环，但 LLM prompt 极度膨胀、自动化测试几乎为空、后端仅代理无业务逻辑，工程可测试性是主要短板。

## 项目地图

- 项目根目录：`/Users/allure/Desktop/七牛云项目/FriesCalendar`
- 项目名称：薯条日历 FriesCalendar（题目一：语音版日历工具）
- 语言与框架：
  - iOS App：Swift 5 + SwiftUI，仅用苹果系统框架（EventKit/Speech/AVFoundation/PhotosUI/UIKit/Security），无第三方 Swift Package（README 第 219 行）
  - 后端：Python 3 + FastAPI + SQLAlchemy(async) + aiomysql + pydantic-settings + python-jose + passlib/bcrypt + Pillow + httpx（`backend/requirements.txt`）
  - LLM：DeepSeek（`deepseek-v4-flash`，默认经后端代理）
  - 生图：SiliconFlow `Tongyi-MAI/Z-Image-Turbo`（默认经后端代理）
- 运行入口：
  - iOS：`FriesCalendarApp.swift` → `RootView` → `ContentView`（Tab 导航）
  - 后端：`uvicorn app.main:app`（`backend/app/main.py:30`）
  - 演示环境后端：`https://lzxz.xyz`（README 第 169 行）
- 边界识别：
  - `FriesCalendar/`：SwiftUI App（App/Features/Services/Models/Components/DesignSystem）
  - `backend/app/`：FastAPI 后端（api/core/db/models/schemas/services）
  - `FriesCalendarTests/`、`FriesCalendarUITests/`：测试 target（几乎为空）
  - `docs/images/`：实机截图
- 待验证：iOS 端为 44 个 Swift 文件（事实），但只能在 Xcode 编译验证；后端无任何测试文件（事实）。

## 产品与商业场景

- 目标用户：希望用自然语言而非逐项填表管理日程的 iPhone 用户（README 第 23-31 行）。
- 场景痛点：传统日历适合精确录入，但真实生活用自然语言描述需求更自然；逐个选日期/时间/提醒/重复规则本身是负担。
- 输入/处理/输出/反馈闭环：
  - 输入：长按语音（实时转写）或键盘输入一句话
  - 处理：LLM 第一阶段判断是否读日历及范围 → EventKit 读取日历上下文 → LLM 第二阶段生成结构化 JSON 计划 → 本地校验 → 用户确认卡片
  - 输出：确认后 EventKit 写入苹果日历（创建/修改/删除/完成/提醒）
  - 反馈：今日任务、薯条奖励（普通/番茄酱）、本周统计、AI 建议
- 独特价值：两阶段 LLM 决策 + 确认后才写入日历，避免大模型误操作；薯条奖励把完成记录游戏化（每日上限 5 根）。
- 最可能打动评委的体验瞬间：说出"明天上午 9 点到 10 点安排组会，下午 2 点到 4 点写论文，两个都提前 10 分钟提醒我"，系统一次性理解多任务+提醒，生成确认卡片，确认后批量写入。
- 商业化分析（基于产品形态的假设）：
  - 付费方/使用者/决策者：个人用户；iOS 日历重度用户
  - 获客渠道：App Store、效率工具社区、实训营展示
  - 交付成本：依赖 LLM token，每次语音交互两阶段 LLM 调用；生图分享额外成本
  - 持续使用理由：日历是高频刚需，薯条奖励增加粘性
  - 合规/隐私：日历数据敏感，需授权；语音送第三方 LLM
  - 竞争替代：Siri、iOS 原生日历、Fantastical 语音输入
  - 可能收费方式：订阅（LLM 成本转嫁）、免费+自配 API Key
  - 限制：仅 iOS、需 Apple Developer 证书分发（README 第 194-196 行）

## 架构拆解

文字架构图：

```
[语音输入/文字输入]
   │
   ▼
[SpeechRecognitionService]  (SFSpeechRecognizer 实时转写)
   │
   ▼
[HomeConversationStore] ──► [SchedulePlannerClient.makeCalendarQuery]  (阶段1: LLM 判断是否读日历+范围)
   │                                        │
   │                                        ▼
   │                          [LLMChatClient / 后端代理 /api/llm/chat/completions]
   │                                        │
   │                                        ▼
   │                          [CalendarContextQuery 解码 + 修复重试 3 次]
   │
   │ (should_read_calendar=true)
   ▼
[CalendarEventService.contextSummary]  (EventKit 读取苹果日历, prefix 80/120 事件)
   │
   ▼
[SchedulePlannerClient.makePlan]  (阶段2: LLM 生成结构化 SchedulePlanResponse)
   │                                  │
   │                                  ▼
   │                    [本地修复重试 + sanitizedJSONContent 去 code fence]
   │                                  │
   │                                  ▼
   │                    [SchedulePlanValidator]  (本地校验: canConfirm/blockingIssues)
   │                                  │
   │                                  ▼
   │                    [ScheduleOperationMapper]  (plan → CalendarOperationBatch)
   │
   │ (用户确认卡片)
   ▼
[CalendarEventService.execute]  (EventKit 写入: create/update/delete/complete/removeReminder)
   │
   ▼
[今日任务 + 薯条奖励 + 统计更新]
   │
   ▼
[ProfileAISuggestionStore / ScheduleShareStore]  (AI 建议 + 生图分享, 经后端代理 /api/images/generations)
```

关键请求追踪（语音创建日程，核心价值链）：
1. `SpeechRecognitionService.startRecording`（`Services/SpeechRecognitionService.swift`）转写
2. `SchedulePlannerClient.makeCalendarQuery`（`Services/SchedulePlannerClient.swift:23`）阶段1 LLM
3. `CalendarEventService.contextSummary`（`Services/CalendarEventService.swift:14`）读 EventKit
4. `SchedulePlannerClient.makePlan`（`Services/SchedulePlannerClient.swift:58`）阶段2 LLM
5. `SchedulePlanValidator.validate`（`Services/SchedulePlanValidator.swift`）本地校验
6. `ScheduleOperationMapper.operationBatch`（`Services/ScheduleOperationMapper.swift:4`）映射
7. 用户确认 → `CalendarEventService.execute`（`Services/CalendarEventService.swift:66`）写入

后端架构（纯代理 + 账号）：
- `api/auth.py`：注册/登录/captcha/me，bcrypt + JWT
- `api/profile.py`：头像昵称
- `api/llm.py`：代理 `/chat/completions`（`backend/app/api/llm.py:13`）
- `api/images.py`：代理 `/images/generations`（`backend/app/api/images.py:13`）
- `services/captcha.py`：内存验证码（PIL 渲染）
- `services/avatar_storage.py`：本地文件头像存储
- `db/migrations.py`：手写 SQL ALTER 增量迁移（非 Alembic）

数据流/状态流/错误流：
- 数据流：语音→文本→LLM查询决策→EventKit上下文→LLM计划→校验→确认→EventKit写入
- 状态流：`SchedulePlanResponse.status` 有 `ready/answer/question/error`
- 错误流：LLM 返回非法 JSON → 修复重试 3 次 → `errorResponse`；`finishReason=="length"` → `truncatedOutput`
- 外部服务：DeepSeek LLM、SiliconFlow 生图
- 数据库：MySQL（async aiomysql）
- 认证：JWT Bearer（`services/security.py`），token 存 iOS Keychain

## 工程评分

| 维度 | 分数 | 证据 |
| --- | --- | --- |
| 产品完成度 | 4 | 完整闭环：语音→理解→确认→写入→奖励→分享。实机截图5张。扣分：仅 iOS、无 IPA 分发 |
| 架构边界 | 4 | iOS/后端边界清晰；两阶段 LLM 决策是亮点；本地校验+确认守护写入安全。扣分：后端纯代理无业务逻辑、prompt 全在客户端 |
| 可维护性 | 3 | SwiftUI 分层清晰（Features/Services/Models）。扣分：`SchedulePlannerClient.swift` 1329 行单文件，prompt 占 800+ 行；后端无 service 层 |
| 可测试性 | 2 | iOS 测试 target 为空模板（`FriesCalendarTests.swift` 仅占位）；后端零测试文件。扣分严重 |
| 可观测性 | 2 | 无结构化日志、无 metrics；LLM 调用无 tracing |
| 安全隐私 | 4 | bcrypt+JWT+Keychain+captcha+后端代理 API Key+确认后写入。扣分：captcha 内存存储不抗重启、CORS allow_credentials=False 但配 origin |
| 性能并发 | 3 | EventKit 读 prefix 80/120 事件限流；后端 async。扣分：两阶段 LLM 串行、无并发控制 |
| 资源释放 | 3 | `httpx.AsyncClient` with 正确释放；iOS speech 任务 cancel 正确。扣分：无 LLM 超时熔断退避 |
| 成本控制 | 3 | 无 token 预估、无缓存、每次语音两阶段 LLM。用户可自配 Key 转嫁成本 |
| 部署恢复 | 3 | 后端 systemd/supervisor 建议清晰；auto_create_tables+手写迁移。扣分：无容器化、无 CI |
| 文档和上手难度 | 4 | README 详尽（部署/接口/安全）；后端 README。扣分：无架构决策文档、无 prompt 设计说明 |

问题分级：

- 阻断：无
- 重要：
  - 可测试性（重要）：iOS 测试为空模板，后端零测试。触发条件：任何回归都无保护。修复方向：补 LLM 决策/校验/映射的单元测试。
  - 可维护性（重要）：`SchedulePlannerClient.swift` 1329 行，prompt 800+ 行内嵌代码，难维护难迭代。修复方向：prompt 外置+模板化+拆分文件。
  - captcha 内存存储（重要）：`services/captcha.py:20` 内存 dict，重启丢失、多实例不共享。修复方向：换 Redis。
  - 头像本地文件存储（一般）：`avatar_storage.py` 本地磁盘，多实例不一致。修复方向：换对象存储。
- 一般：
  - 后端无 service 层，API 直接操作。
  - 手写 SQL 迁移非 Alembic，难追踪。
  - 无结构化日志与监控。
  - LLM 调用无重试退避（仅 JSON 修复重试）。
- 建议：
  - prompt 拆分为可版本化管理的外部资源。
  - 后端补 Alembic 迁移。
  - 增加生图/LLM 调用的 rate limit。

## 优点

1. 安全意识到位（产品级）：bcrypt 密码哈希（`services/security.py:23`）、JWT 带 type 校验（`security.py:48`）、图片验证码防刷（`services/captcha.py`，PIL 渲染+`secrets.compare_digest` 恒定时间比较）、API Key 后端代理不下发（`api/llm.py`）、token 存 Keychain、日历写入前必须用户确认（README 第 258 行）。
2. 两阶段 LLM 决策架构：先判断是否读日历及范围（`makeCalendarQuery`），再生成结构化计划（`makePlan`），避免一次性 prompt 过载，且读日历范围最小化（`SchedulePlannerClient.swift:23/58`）。
3. 人机协同闭环：LLM 生成计划→本地校验（`SchedulePlanValidator`）→用户确认卡片→才写入 EventKit，避免大模型误操作（`CalendarEventService.swift:66`）。
4. LLM 输出修复重试 + JSON 容错：3 次重试带错误信息（`SchedulePlannerClient.swift:41/78`），`sanitizedJSONContent` 去 code fence 提取 JSON（`swift:1087`），`finishReason=="length"` 检测截断。
5. 本地兜底逻辑丰富：`SchedulePlannerClient` 有大量本地关键词匹配兜底（greeting/查询/总结/建议/批量操作），LLM 失败时仍有基础体验（`swift:191/322/371/515`）。
6. 后端代理设计干净：LLM/生图代理统一处理超时/错误/默认模型，错误信息提取完善（`api/llm.py`、`api/images.py:75`）。
7. SwiftUI 分层规范：Features/Services/Models/Components/DesignSystem 清晰，仅用系统框架无第三方依赖（README 第 219 行）。

## 缺点、风险与改进优先级

1. 可测试性（重要）：iOS 测试 target 为 Xcode 默认空模板（`FriesCalendarTests.swift` 仅 `// Write your test here`），后端零测试文件。核心 LLM 决策/校验/映射逻辑无任何自动化测试保护。→ 补单元测试。
2. prompt 膨胀（重要）：`SchedulePlannerClient.swift` 的 `planningMessages` 系统 prompt 约 800+ 行内嵌字符串，覆盖上下文分级/事实来源/输出规则/查询格式/建议格式/task结构/target结构/action/category/priority/提醒/模糊规则/续问/重复规则。难维护、难版本化、难 A/B 测试。→ prompt 外置+模板化。
3. captcha 内存存储（重要）：单进程内存 dict，重启丢失、多 worker 不共享、无上限可能被刷爆内存。→ 换 Redis。
4. 头像本地文件存储（一般）：`avatar_storage.py` 写本地磁盘，多实例部署不一致。→ 换对象存储。
5. 后端无 service 层（一般）：API 路由直接操作 DB/代理，业务逻辑无封装。→ 抽 service 层。
6. 手写 SQL 迁移（一般）：`db/migrations.py` 用 `INFORMATION_SCHEMA` 判断列后 `ALTER TABLE`，非 Alembic，难追踪版本。→ 引入 Alembic。
7. LLM 无重试退避（一般）：仅 JSON 修复重试，网络/超时错误无退避。→ 加指数退避。
8. 无结构化日志与监控（一般）。
9. 仅 iOS 无 Android/Web（建议）。

## 复用性矩阵

- 最值得保留的设计：
  - 两阶段 LLM 决策（先判断读日历范围，再生成计划）
  - 确认后才写入 EventKit 的人机协同闭环
  - 后端代理 API Key 不下发的安全设计
  - bcrypt+JWT+Keychain+captcha 的账号安全实践
  - LLM 输出 JSON 容错与修复重试
- 最需要警惕的问题：
  - 1329 行单文件 prompt 膨胀
  - 零自动化测试
  - captcha/头像内存/本地存储无法多实例
- 可直接复用：后端 LLM/生图代理（`api/llm.py`、`api/images.py`）、账号安全（`services/security.py`）、captcha 渲染（`services/captcha.py`）、`sanitizedJSONContent` JSON 容错
- 改造后复用：两阶段 LLM 决策模式（需 prompt 外置）、SchedulePlanValidator 本地校验模式、EventKit 读写服务（iOS 限定）
- 不应复用：1329 行单文件 prompt 内嵌、内存 captcha、本地文件头像、手写 SQL 迁移、空测试模板

| 复用维度 | 分数 | 理由 |
| --- | --- | --- |
| 技术复用 | 3 | 后端代理+安全+captcha 可复用；iOS 端 EventKit/Speech 可参考；prompt 需重构 |
| 产品复用 | 3 | 语音日历闭环完整但仅 iOS；两阶段决策模式可迁移到其他 LLM+系统API场景 |
| 商业复用 | 3 | 有账号/代理/部署方案；但无 IPA 分发、无计费、无多租户；LLM 成本转嫁模式可行 |

## 值得学习的内容

按学习收益排序：

1. 【进阶架构取舍】两阶段 LLM 决策：何时让 LLM 做路由判断（是否读日历、读什么范围），何时让 LLM 做内容生成。阅读 `SchedulePlannerClient.swift:23 makeCalendarQuery` + `:58 makePlan`。
2. 【可迁移模式】人机协同闭环：LLM 生成→本地校验→用户确认→才执行副作用（写日历），避免 LLM 误操作。阅读 `SchedulePlanValidator` + `CalendarEventService.execute`。
3. 【可复刻实验】LLM 输出 JSON 容错：去 code fence + 首尾花括号提取 + 修复重试带错误信息。阅读 `SchedulePlannerClient.swift:1087 sanitizedJSONContent` + `:999 repairMessages`。
4. 【可迁移模式】后端代理第三方 API Key 不下发客户端的安全设计。阅读 `backend/app/api/llm.py`。
5. 【初学者概念】iOS 账号安全实践：bcrypt+JWT+Keychain+captcha 的组合。阅读 `services/security.py` + `services/captcha.py`。
6. 【开放问题】如何让膨胀的 LLM prompt 可维护、可版本化、可 A/B 测试（本项目是反面教材）。
7. 【开放问题】本地兜底关键词匹配与 LLM 决策的边界（本项目做了大量 `looksLike*` 本地兜底）。

## 结构化 YAML 摘要

```yaml
project: FriesCalendar
one_line_judgment: "完成度较高的语音日历助手，两阶段 LLM 决策+确认后写入的人机协同闭环是核心创新，安全意识到位，但 prompt 膨胀、自动化测试几乎为空、后端仅代理无业务逻辑"
product_type: "iOS 语音日历助手（自然语言理解+EventKit 写入+游戏化奖励）"
target_users: ["希望用自然语言管理日程的 iPhone 用户", "iOS 日历重度用户"]
core_loop: "语音/文字输入 -> LLM 两阶段决策(判断读日历+生成计划) -> 本地校验 -> 用户确认 -> EventKit 写入 -> 薯条奖励+统计+AI建议"
architecture_style: "iOS SwiftUI 前端 + FastAPI 代理后端，两阶段 LLM 决策，人机协同确认闭环"
stack: ["Swift 5", "SwiftUI", "EventKit", "Speech", "AVFoundation", "Python 3", "FastAPI", "SQLAlchemy async", "aiomysql", "pydantic-settings", "python-jose", "passlib/bcrypt", "Pillow", "httpx", "DeepSeek LLM", "SiliconFlow 生图"]
strongest_patterns: ["两阶段 LLM 决策(先判断读日历范围再生成计划)", "确认后才写入 EventKit 的人机协同闭环", "后端代理 API Key 不下发客户端", "bcrypt+JWT+Keychain+captcha 账号安全", "LLM 输出 JSON 容错与修复重试", "本地关键词兜底降低 LLM 依赖"]
main_risks: ["iOS 测试 target 为空模板、后端零测试", "SchedulePlannerClient.swift 1329 行 prompt 膨胀难维护", "captcha 内存存储不抗重启不多实例", "头像本地文件存储多实例不一致", "手写 SQL 迁移非 Alembic", "LLM 无网络重试退避", "仅 iOS 无 Android/Web"]
business_scenarios: ["iPhone 用户语音管理日程", "学生/职场人士自然语言安排任务", "效率工具场景的语音+AI 集成", "iOS 原生+后端代理架构参考"]
reusable_assets: ["backend/app/api/llm.py（LLM 代理）", "backend/app/api/images.py（生图代理）", "backend/app/services/security.py（bcrypt+JWT）", "backend/app/services/captcha.py（PIL 验证码）", "SchedulePlannerClient 两阶段决策模式", "sanitizedJSONContent JSON 容错"]
non_reusable_parts: ["SchedulePlannerClient.swift 1329 行单文件 prompt 内嵌", "内存 captcha 存储", "本地文件头像存储", "手写 SQL 迁移", "空测试模板"]
scores:
  product: 4
  architecture: 4
  engineering: 3
  reuse: 3
  commercialization: 3
evidence:
  - "FriesCalendar/Services/SchedulePlannerClient.swift:23 makeCalendarQuery（阶段1 LLM 决策）"
  - "FriesCalendar/Services/SchedulePlannerClient.swift:58 makePlan（阶段2 LLM 生成计划）"
  - "FriesCalendar/Services/SchedulePlannerClient.swift:732 planningMessages（800+行系统 prompt）"
  - "FriesCalendar/Services/SchedulePlannerClient.swift:1087 sanitizedJSONContent（JSON 容错）"
  - "FriesCalendar/Services/CalendarEventService.swift:66 execute（确认后写入 EventKit）"
  - "FriesCalendar/Services/SchedulePlanValidator.swift（本地校验）"
  - "FriesCalendar/Services/ScheduleOperationMapper.swift:4 operationBatch（plan 映射）"
  - "FriesCalendar/Services/SpeechRecognitionService.swift（SFSpeechRecognizer 转写）"
  - "backend/app/api/llm.py:13 proxy_chat_completions（LLM 代理）"
  - "backend/app/api/images.py:13 proxy_image_generations（生图代理）"
  - "backend/app/services/security.py:23 hash_password（bcrypt）"
  - "backend/app/services/security.py:31 create_access_token（JWT）"
  - "backend/app/services/captcha.py:17 CaptchaStore（内存验证码）"
  - "backend/app/services/avatar_storage.py（本地文件头像）"
  - "backend/app/db/migrations.py（手写 SQL 迁移）"
  - "FriesCalendarTests/FriesCalendarTests.swift（空测试模板）"
  - "backend 无 test_*.py 文件（事实）"
  - "44 个 Swift 源文件（事实）"
  - "README.md:169 演示后端 https://lzxz.xyz"
confidence: "高"
```
