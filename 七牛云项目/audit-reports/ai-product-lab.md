# ai-product-lab (BabelFlux / 巴别流) 项目审查报告

## 一句话判断

ai-product-lab（对外品牌 BabelFlux / 巴别流）是一个三端（Web + 桌面悬浮窗 + FastAPI 后端）AI 同声传译系统，以阿里云百炼 DashScope LiveTranslate 实时模型为核心链路，叠加实时纠偏与会后完整纠偏双层 LLM 修正，核心 pipeline 编排极为精细但单文件复杂度极高，是一个产品体验打磨充分、真实模型链路打通、但工程结构存在明显可维护性风险的项目。

---

## 项目地图

| 维度 | 事实 |
|------|------|
| 项目名称 | ai-product-lab（品牌名 BabelFlux / 巴别流 同传） |
| 仓库路径 | `/Users/allure/Desktop/七牛云项目/ai-product-lab` |
| 语言/框架 | Python 3.11+ FastAPI（后端）+ Vue 3 + Vite + Pinia + TypeScript（Web 前端）+ Tauri v2 + Rust（桌面悬浮窗） |
| 运行入口 | 后端 `backend/app/main.py`（uvicorn app.main:app）、Web 前端 `frontend/src/main.ts`（vite）、桌面端 `desktop/src-tauri/src/main.rs`（tauri） |
| 核心依赖 | FastAPI + uvicorn + asyncio + pydantic + httpx + websockets（后端）；Vue 3 + Pinia + GSAP + video.js（前端）；Tauri v2 + wasapi + webview2_com（桌面端 Rust） |
| 代码规模 | 后端 Python ~5,462 行（app），后端测试文件 10 个；Web 前端 ~7,909 行，前端测试 6 个；桌面 Vue/TS ~995 行，Rust ~420 行；docs 31 份 |
| 外部服务 | 阿里云百炼 DashScope：qwen3.5-livetranslate-flash-realtime（实时同传）、qwen-flash（实时纠偏）、qwen-plus（会后纠偏）、qwen3-tts-flash-realtime（TTS）、ffmpeg（媒体解码） |
| 部署方式 | 本地脚本启动（`scripts/dev-backend.sh` + `scripts/dev-frontend.sh`），桌面端 `npm run tauri build` 出安装包 |
| 默认运行模式 | `MODEL_PROVIDER=mock`，零配额跑通全链路 |

### 目录边界

```
backend/
  app/api/          → health / sessions / model_gateway / ws（WebSocket 路由）
  app/services/     → pipeline（同传管线编排）/ revision（实时纠偏）/ report（报告生成）
                      / media（ffmpeg 解码）/ handoff（桌面投送令牌）/ session_store / session_history
  app/services/providers/ → base / mock / dashscope（config / client / realtime / errors）
  app/core/config.py → pydantic Settings
  tests/            → 10 个测试文件
  scripts/          → 真实模型联调脚本
frontend/           → Vue 3 Web 工作台（字幕/报告/输入源/设置）
desktop/            → Tauri v2 桌面悬浮字幕窗（Vue + Rust）
  src-tauri/src/    → main.rs / audio_capture.rs（WASAPI loopback）/ native_drag.rs
docs/               → 31 份文档（架构/设计/联调/审计/计划）
scripts/            → dev-backend.sh / dev-frontend.sh / check.sh
```

---

## 产品与商业场景

### 目标用户与场景痛点

- **目标用户**：参加英文技术分享/国际会议/网课的中文用户，需要实时双语字幕与中文语音。
- **场景痛点**：同传跟不上、听不懂、来不及记；已输出的识别/翻译错误无法纠正；单一来源（只能麦克风或只能 URL）限制使用场景；移动中无法使用（需桌面悬浮窗）。
- **核心闭环**：多源输入（URL/麦克风/系统音频/屏幕/浏览器标签页/本地视频/演示模式）→ 后端 ffmpeg 解码或前端 PCM 采集 → WebSocket 推送 → DashScope LiveTranslate 实时识别+翻译 → 实时纠偏（qwen-flash 跨句复核）→ 双语字幕+琥珀高亮修正 → 会后完整纠偏（qwen-plus 全局校正）→ TXT/SRT/Markdown/JSON 四格式报告导出。

### 独特价值

- **实时纠偏（在线）**：传译进行中由 qwen-flash 跨句复核，结合后文修正前句的术语/数字/否定/一词多义错误，前端琥珀高亮即时展示。这是区别于普通实时翻译的核心创新。
- **会后完整纠偏**：结束后 qwen-plus 通读全场做全局校正、统一术语、生成摘要；六大领域（通用/技术/商务/教育/医疗/法律）差异化 PROMPT。
- **三端协同**：Web 工作台 + 桌面悬浮窗（Tauri 透明置顶）+ deep-link 投送（handoff token 300s TTL），桌面端可独立采集系统音频。
- **多源输入**：7 种输入模式覆盖几乎所有音源场景。
- **打动评委的体验瞬间**：演讲者说到 "several pieces" 被实时识别为 "several 位"，纠偏瞬间将其修正为 "several 件" 并琥珀高亮——观众看到 AI 在"自我纠错"，这种动态修正体验极具冲击力。

### 商业化分析

| 维度 | 分析 |
|------|------|
| 付费方 | 在线教育平台、企业培训部门、会议服务商 |
| 使用者 | 学员/参会者（B2B2C） |
| 获客渠道 | 桌面悬浮窗病毒传播、Web 工作台 SaaS、会议系统集成 |
| 交付成本 | 中等——单 WebSocket 管线（LiveTranslate 一条连接完成 ASR+翻译+TTS），纠偏为异步后台任务不阻塞主链路 |
| 持续使用理由 | 报告历史沉淀、术语表积累、四格式导出满足归档需求 |
| 商业化障碍 | 强依赖阿里云百炼单一供应商；桌面端仅 Windows；模型策略 UI 占位未接入真实路由 |

---

## 架构拆解

### 文字架构图

```
┌─────────────────────────────────────────────────────┐
│ Web 工作台 (Vue 3)          桌面悬浮窗 (Tauri v2)    │
│  ├─ 字幕视图(GSAP动画)       ├─ 透明置顶字幕          │
│  ├─ 输入源选择(7种)          ├─ WASAPI loopback采集   │
│  ├─ 报告历史/下载            ├─ deep-link handoff     │
│  └─ AudioWorklet PCM采集     └─ 独立会话/接管Web会话   │
└──────────┬──────────────────────┬────────────────────┘
           │ WebSocket(PCM二进制帧 + JSON事件)          │
           ▼                                          │
FastAPI 后端 (asyncio)                                │
  ├─ ws.py: 会话WebSocket路由                          │
  ├─ pipeline.py: 同传管线编排(核心)                    │
  │   ├─ LiveTranslateSession(DashScope WS)            │
  │   │   └─ 实时ASR+翻译(+可选TTS)                    │
  │   ├─ RealtimeReviser(qwen-flash跨句纠偏)           │
  │   ├─ 源/译文段落归段+对齐+显示分块                  │
  │   └─ 事件发射(transcript/translation/revision)     │
  ├─ revision.py: 实时纠偏(限速+置信度过滤)             │
  ├─ report.py: 会后完整纠偏(qwen-plus)+四格式生成      │
  ├─ media.py: ffmpeg解码→16k PCM                      │
  ├─ handoff.py: 投送令牌(issue/claim/300s TTL)        │
  ├─ session_store.py: 进程内会话状态                   │
  └─ session_history.py: 历史索引                       │
           │                                          │
           ▼                                          │
阿里云百炼 DashScope                                   │
  ├─ qwen3.5-livetranslate-flash-realtime (实时同传)   │
  ├─ qwen-flash (实时纠偏)                             │
  ├─ qwen-plus (会后完整纠偏)                          │
  └─ qwen3-tts-flash-realtime (TTS)                   │
```

### 请求追踪（一条完整请求）

1. 前端 WebSocket 连接 `/api/ws/sessions/{session_id}`，发送 `start_session`（`backend/app/api/ws.py:46` session_socket）。
2. 后端校验 ws token（`backend/app/services/handoff.py:70` claim），创建 `SessionRecord`（`session_store.py:48`）。
3. 按 `inputMode` 选择音频入口：URL → 后端 ffmpeg 解码（`media.py` iter_pcm_frames）；采集类 → 前端 PCM 二进制帧推入 queue。
4. `InterpretationPipeline.run_media` / `run_pcm_stream`（`pipeline.py:185` / `227`）创建 `LiveTranslateSession`（`providers/dashscope/realtime.py:47`）连接 DashScope WS。
5. PCM 帧 `session.feed()`（`realtime.py:102`）→ DashScope VAD 自动断句 → `source_partial`/`source_final`/`translation_partial`/`translation_final` 事件。
6. `_consume` → `_handle`（`pipeline.py:402`/`426`）归段：源用 item_id、译文用 response_id FIFO 绑定，抵抗译文滞后 ~2.8s 的错配。
7. 译文 final 后 `_on_segment_complete`（`pipeline.py:1659`）→ 后台 `RealtimeReviser.review`（`revision.py:107`）qwen-flash 跨句复核 → `_apply_revision` 发 `revision_event`。
8. 会话结束 → `finalize`（`ws.py:85`）→ `generate_session_report`（`report.py:72`）qwen-plus 全局校正 → 四格式报告 → `session_report{reportId}`。

### 关键设计决策

- **单条 WebSocket 完成实时 ASR+翻译+TTS**：选择 DashScope LiveTranslate 而非分离的 ASR+MT+TTS 管线，用厂商实时模型降低端到端延迟，简化编排复杂度。（事实：`README.md:38`，`realtime.py:47` LiveTranslateSession 封装单条 WS）
- **双层纠偏（实时+会后）**：实时纠偏用 qwen-flash（低延迟、跨句窗口 4 句、限速 6 次/分钟），会后纠偏用 qwen-plus（强模型、全场通读）。按任务强度拆模型兼顾速度与质量。（事实：`revision.py:64-90` RealtimeReviser，`report.py:25-46` build_final_correction_prompt）
- **FIFO response_id 绑定**：译文比源滞后约 2.8s，可能跨越下一句 speech_started；用 response_id 按 FIFO 绑定到最早未配译文的段，抵抗错配。（事实：`pipeline.py:472` _bind_response 注释）
- **进程内会话状态**：单机部署用进程内字典，演示场景足够；预留 Redis/SQLite 扩展。（事实：`session_store.py:1-7` 模块文档）
- **桌面端 WASAPI loopback**：系统音频走原生 WASAPI 而非 WebView2 getUserMedia，绕过浏览器权限限制。（事实：`desktop/src-tauri/src/audio_capture.rs:58` platform mod，`main.rs:31` 注释）

---

## 工程评分

| 维度 | 评分 | 证据 |
|------|------|------|
| 产品完成度 | 5 | 三端（Web+桌面+后端）完整，7 种输入源、双层纠偏、四格式报告导出、报告历史、术语表、领域策略均落地；真实模型链路打通并有联调脚本验证。README 近期功能修正清单详尽。 |
| 架构边界 | 3 | 后端 services 分层合理（pipeline/revision/report/media/handoff），但 pipeline.py 单文件 ~1788 行承载了段落归段、源/译文对齐、显示分块、CJK/Latin 分割、重复折叠、语言检测等全部逻辑，职责严重过载。桌面端与 Web 端共享 Vue 技术栈是合理选择。 |
| 可维护性 | 2 | pipeline.py 是最大风险：1788 行单文件，20+ 个私有方法处理文本合并/折叠/分块/对齐，逻辑极复杂且高度耦合；`_merge_source_partial`/`_collapse_source_repetition` 等方法嵌套层级深。任何修改都有回归风险。 |
| 可测试性 | 3 | 后端 10 个测试文件（pipeline/sessions/health/model_gateway/dashscope_provider/e2e_fixture 等），前端 6 个测试文件，桌面端有 FloatingCaption.test.ts。但 pipeline.py 的复杂文本处理逻辑缺乏针对性单元测试。 |
| 可观测性 | 2 | WebSocket 事件流有 source_sync_state 同步状态；但无结构化日志框架（未见 logging 配置）、无 metrics、无 tracing。错误处理大量 `except Exception: noqa: BLE001` 静默吞异常。 |
| 安全隐私 | 3 | WebSocket token 校验（handoff.py issue/claim）；`ALLOWED_MEDIA_HOSTS` 可限制在线 URL host；`REQUIRE_MODEL_GATEWAY_AUTH` 开关。但默认关闭鉴权，CORS 允许 `*` methods/headers，音频 PCM 明文传输，进程内 token 存储无加密。 |
| 性能并发 | 4 | asyncio 全异步管线；实时纠偏为后台 asyncio.Task 不阻塞主链路；partial 事件限速（PARTIAL_THROTTLE_S=0.08）；PCM queue 有界（MAX_PCM_QUEUE_FRAMES=25）。减分：pipeline 单实例串行处理，无并发会话池。 |
| 资源释放 | 3 | pipeline 有 `finally: consumer.cancel(); await session.close()`；`_await_reviews` 等待后台纠偏任务。但大量 `except Exception: pass` 静默关闭，WS 断开后后台任务清理依赖 `return_exceptions=True`。 |
| 成本控制 | 3 | 双层纠偏有限速（6 次/分钟）；mock 模式零成本；会后纠偏异步不阻塞基础报告下载。但实时纠偏每句 final 都触发 LLM 调用（窗口>=2 即触发），长会话成本累积；强依赖单一供应商无成本优化路由。 |
| 部署恢复 | 2 | 仅本地脚本启动，无 Docker/容器化部署，无 K8s，无 CI/CD；进程内会话状态重启即丢失（报告落盘但会话运行态不持久化）。`providers.example.yaml` 有供应商配置但实际路由未实现。 |
| 文档 | 4 | docs/ 31 份文档覆盖架构/设计/联调/审计/计划/规范；README 详尽含近期功能修正清单、架构图、模型链路、WebSocket 协议、导出格式说明。减分：docs/ 含多个 AI 同声传译无关的项目计划文档（小说转剧本、英语口语陪练），说明仓库命名 ai-product-lab 是多项目实验室。 |
| 上手难度 | 3 | mock 模式可零配额跑通；但三端依赖（Python 3.11+ / Node 20.19+ / Rust stable / WebView2 / ffmpeg）安装复杂；桌面端仅 Windows；无 Docker 一键部署。 |

### 问题分级

**阻断级**：无。

**重要级**：
- **pipeline.py 单文件 1788 行、20+ 私有方法、职责严重过载**（`backend/app/services/pipeline.py`）：段落归段、源/译文对齐、显示分块、CJK/Latin 分割、重复折叠、语言检测、续句合并、噪声过滤全部在一个类里。这是可维护性的最大风险点，任何修改都需理解整条调用链。
- **大量 `except Exception: noqa: BLE001` 静默吞异常**（`pipeline.py:380`/`1672`，`revision.py:138`，`realtime.py:90` 等）：纠偏失败、语言检测失败、WS 关闭等异常被静默，生产环境难以诊断问题根因。
- **无容器化部署**：仅本地脚本启动，无 Dockerfile / docker-compose，评委/用户复现环境门槛高。
- **进程内会话状态，重启即丢失**（`session_store.py`）：会话运行态不持久化，服务重启中断所有进行中会话。

**一般级**：
- 模型策略 UI（智能默认/快速低延迟/高准确/成本优先/指定供应商）是占位，未接入真实 provider 路由（`README.md:80-81` 明确声明）。
- `gummy`/`fun_asr` 等 provider 回退未实现。
- 桌面端仅 Windows（WASAPI + WebView2），macOS/Linux 不可用。
- CORS 默认 `allow_methods=["*"]` + `allow_headers=["*"]`，生产需收紧。
- docs/ 混入无关项目计划文档（小说转剧本、英语口语陪练），仓库定位模糊。

**建议级**：
- 拆分 pipeline.py 为 segmenter（归段/对齐）+ display（分块/折叠）+ language（检测/锁定）+ pipeline（编排）多模块。
- 增加结构化日志（structlog/logging）替代静默 except。
- 补充 Dockerfile + docker-compose。
- 会话状态持久化到 SQLite/Redis。
- 桌面端跨平台支持（macOS CoreAudio / Linux PulseAudio）。

---

## 优点

1. **实时纠偏是核心创新且真实可用**：传译进行中 qwen-flash 跨句复核，高置信度时产出 revision_event 前端琥珀高亮——这不是事后修正而是"在线自我纠错"，在同传产品中极具差异化。且有限速（6 次/分钟）+ 置信度过滤（0.62）+ 窗口控制（4 句）避免刷屏。（`revision.py:64-90` RealtimeReviser，`pipeline.py:1659-1711` _on_segment_complete → _apply_revision）
2. **会后完整纠偏+四格式报告**：qwen-plus 全场通读校正 + 六大领域差异化 PROMPT + TXT/SRT/Markdown/JSON 四格式导出，报告先出基础版再异步补全纠偏，不阻塞下载。产品体验闭环完整。（`report.py:25-46` build_final_correction_prompt，`README.md:176-184` 导出格式说明）
3. **三端协同设计精巧**：Web 工作台 + Tauri 桌面悬浮窗 + deep-link handoff（300s TTL token），桌面端可接管 Web 会话（只订阅字幕事件）或独立创建会话。WASAPI loopback 绕过浏览器权限限制采集系统音频。（`handoff.py:46-80`，`desktop/src-tauri/src/audio_capture.rs:58`）
4. **多源输入覆盖全面**：URL/麦克风/系统音频/屏幕/浏览器标签页/本地视频/演示模式 7 种输入，且采集类音源统一重采样到 16k PCM 经 WS 二进制帧推送，后端按 inputMode 分流。（`ws.py:34-40` CLIENT_CAPTURE_MODES，`pipeline.py:185`/`227` run_media vs run_pcm_stream）
5. **FIFO response_id 绑定抵抗译文滞后**：译文比源滞后约 2.8s 可能跨句，用 response_id FIFO 绑定到最早未配译文的段，并处理噪声源过滤/续句合并——这是对厂商实时模型协议行为的深度适配。（`pipeline.py:472-492` _bind_response + _should_skip_response_root）
6. **真实模型链路实测打通**：README 明确所有模型经标准端点实测连通，有联调脚本（prove_realtime_revision.py / e2e_online_url.py）证明实时纠偏"该纠必纠、干净零误纠"。

---

## 缺点风险与改进优先级

| 优先级 | 问题 | 影响 | 建议 |
|--------|------|------|------|
| P1 | pipeline.py 1788 行单文件职责过载 | 可维护性极差，修改回归风险高 | 拆分为 segmenter/display/language/pipeline 多模块 |
| P1 | 大量 except Exception 静默吞异常 | 生产问题难诊断 | 引入结构化日志，区分可恢复异常与需告警异常 |
| P1 | 无容器化部署 | 复现门槛高，无法一键部署 | 补充 Dockerfile + docker-compose |
| P2 | 进程内会话状态重启即丢失 | 服务重启中断进行中会话 | 持久化到 SQLite/Redis |
| P2 | 模型策略 UI 占位未实现 | 用户感知功能缺失 | 接入真实 provider 路由或移除 UI 占位 |
| P2 | 桌面端仅 Windows | 跨平台受限 | 补充 macOS CoreAudio / Linux PulseAudio |
| P2 | 强依赖单一供应商（阿里云百炼） | 供应商风险，无成本优化路由 | 实现 providers.example.yaml 的多供应商路由 |
| P3 | CORS 默认全放开 | 生产安全风险 | 收紧 allow_methods/allow_headers |
| P3 | docs/ 混入无关项目文档 | 仓库定位模糊 | 分仓或归档无关文档 |
| P3 | 无 CI/CD | 代码质量保障缺失 | 补充 GitHub Actions / Gitee pipeline |

---

## 复用性矩阵

| 资产 | 分类 | 复用性 | 说明 |
|------|------|--------|------|
| 双层纠偏架构（实时+会后） | 技术架构 | 可直接复用 | 适用于任何实时翻译/转录系统，qwen-flash 实时 + qwen-plus 会后分级 |
| RealtimeReviser 实时纠偏器 | 技术组件 | 可直接复用 | `revision.py` 限速+置信度过滤+窗口控制+领域 PROMPT，通用性强 |
| DashScope LiveTranslate provider 封装 | 技术组件 | 可直接复用 | `providers/dashscope/realtime.py` 封装厂商 WS 协议为 NormalizedEvent |
| 源/译文段落归段+对齐算法 | 技术实现 | 改造后复用 | `pipeline.py` FIFO response_id 绑定+噪声过滤+续句合并，适配特定厂商协议 |
| 四格式报告生成（TXT/SRT/MD/JSON） | 技术组件 | 可直接复用 | `report.py` 报告模板+降级策略 |
| Tauri 桌面悬浮窗 + WASAPI loopback | 技术组件 | 改造后复用 | `desktop/src-tauri/src/` 透明置顶+原生音频采集，Windows 限定 |
| handoff token 投送机制 | 技术模式 | 可直接复用 | `handoff.py` issue/claim/TTL 一次性令牌，适用于 Web→桌面会话接管 |
| 多源输入 PCM 采集+WS 二进制帧 | 技术模式 | 可直接复用 | 前端 AudioWorklet 16k 重采样 + WS 推流 |
| 同传产品闭环（三端+双层纠偏） | 产品/商业 | 改造后复用 | 产品体验完整，多供应商路由后可商业化 |
| pipeline.py 文本处理逻辑 | 技术实现 | 不应直接复用 | 1788 行单文件过度耦合，应拆分后参考 |
| 进程内会话状态 | 数据模型 | 不应复用 | 无持久化，生产应换 SQLite/Redis |

### 复用性评分

| 维度 | 评分 | 说明 |
|------|------|------|
| 技术复用 | 4 | 双层纠偏架构、RealtimeReviser、DashScope provider、四格式报告、handoff 机制均为高复用资产；pipeline 文本处理需拆分后参考 |
| 产品复用 | 4 | 三端同传产品闭环完整，多源输入+双层纠偏+报告导出体验打磨充分 |
| 商业复用 | 3 | 供应商单一风险，但产品形态清晰，SaaS/桌面分发路径可行 |

---

## 值得学习的内容

### 适合初学者的概念（按学习收益排序）

1. **asyncio WebSocket 管线编排**：FastAPI + asyncio 处理长连接事件流（WS 接收 PCM + 后台 LLM 任务 + 事件发射），`pipeline.py` 的 `run_pcm_stream` 是异步流式处理的范例。
2. **pydantic Settings 配置管理**：`backend/app/core/config.py` 用 pydantic-settings 统一环境变量+类型校验+属性派生。
3. **provider 抽象 + mock 优先**：`providers/base.py` + `providers/mock.py` + `providers/dashscope/` 三层结构，mock 模式零配额跑通全链路。
4. **Tauri v2 桌面应用**：`desktop/src-tauri/src/main.rs` 透明置顶窗口 + 原生拖拽 + WASAPI 采集 + deep-link，是 Rust+Vue 混合桌面的实践。

### 适合进阶者的架构取舍

1. **单条 WS vs 分离管线**：为什么选 DashScope LiveTranslate 而非分离的 ASR+MT+TTS？因为单条 WS 降低端到端延迟、简化编排，但代价是强依赖单一供应商、协议适配复杂（response_id FIFO 绑定、partial 快照 vs 增量 stash 判断）。这是延迟优先 vs 供应商灵活性的取舍。
2. **实时纠偏限速策略**：为什么限速 6 次/分钟 + 窗口 4 句？因为每句 final 都触发 LLM 会刷屏且成本高；限速+窗口控制让纠偏"该纠必纠、干净零误纠"而不泛滥。这是质量 vs 成本/体验的工程权衡。
3. **报告先出基础版再异步补全**：为什么不等会后纠偏完成再出报告？因为短视频不应因强模型纠偏等待阻塞下载；先出基础 TXT/SRT/MD/JSON，再异步更新纠偏状态。这是即时反馈 vs 最终质量的取舍。
4. **进程内状态 vs 持久化**：为什么用进程内字典？因为单机演示场景足够且开发简单，但代价是重启丢失。这是开发速度 vs 生产就绪的取舍。

### 可复刻实验

1. **实时纠偏效果验证**：`backend/scripts/prove_realtime_revision.py` 用真实模型证明"该纠必纠、干净零误纠"。
2. **端到端在线直链**：`backend/scripts/e2e_online_url.py <直链> [秒]` 验证识别/翻译/纠偏/报告全链路。
3. **mock provider 驱动开发**：`MODEL_PROVIDER=mock` 跑通全链路后再接真实模型。
4. **CJK/Latin 显示分块对比**：pipeline 的 _split_source_display vs _split_target_display 在中英文混合内容上的分块效果。

### 可迁移模式

1. **双层纠偏架构**：任何实时文本流（转录/翻译/字幕）都可叠加"实时轻量纠偏 + 会后完整校正"。
2. **FIFO 事件绑定**：任何有生产者-消费者滞后的事件流（如 ASR partial/final + 翻译 response）。
3. **handoff token 投送**：任何 Web→桌面会话接管场景。
4. **四格式报告导出**：任何需要结构化导出的会话系统。

---

## 结构化 YAML 摘要

```yaml
project: ai-product-lab
one_line_judgment: "三端（Web+桌面+FastAPI）AI 同声传译系统，以 DashScope LiveTranslate 为核心+双层 LLM 纠偏（实时 qwen-flash + 会后 qwen-plus），产品体验打磨充分但 pipeline 单文件 1788 行存在严重可维护性风险"
product_type: "AI 同声传译实时双语字幕+纠偏+报告系统（Web工作台+桌面悬浮窗）"
target_users: ["英文技术分享听众", "国际会议参会者", "在线网课学员", "跨语言直播观众"]
core_loop: "多源输入(7种) → DashScope LiveTranslate实时ASR+翻译 → qwen-flash实时跨句纠偏(琥珀高亮) → 双语字幕呈现 → 会后qwen-plus全局校正 → TXT/SRT/MD/JSON四格式报告导出"
architecture_style: "三端协同（Vue3 Web + Tauri桌面 + FastAPI后端），后端 asyncio 事件流编排，双层纠偏（实时轻量+会后完整），单条 WebSocket 完成实时 ASR+翻译+TTS"
stack: ["Python 3.11", "FastAPI", "uvicorn", "asyncio", "pydantic", "httpx", "websockets", "Vue 3", "Vite", "Pinia", "TypeScript", "GSAP", "video.js", "Tauri v2", "Rust", "wasapi", "ffmpeg", "阿里云百炼DashScope"]
strongest_patterns: ["双层纠偏架构(实时qwen-flash跨句复核+会后qwen-plus全局校正)", "RealtimeReviser限速+置信度过滤+窗口控制", "FIFO response_id绑定抵抗译文滞后", "三端协同(deep-link handoff token投送)", "WASAPI loopback原生系统音频采集", "四格式报告先出基础版再异步补全纠偏", "多源输入统一16k PCM WS推流", "provider抽象+mock优先零配额跑通"]
main_risks: ["pipeline.py单文件1788行职责严重过载(可维护性)", "大量except Exception静默吞异常(可观测性)", "无容器化部署(复现门槛高)", "进程内会话状态重启即丢失(可靠性)", "模型策略UI占位未实现(功能缺失)", "桌面端仅Windows(跨平台)", "强依赖单一供应商(供应商风险)"]
business_scenarios: ["英文技术分享实时同传", "国际会议双语字幕", "在线网课翻译辅助", "跨语言直播实时纠偏"]
reusable_assets: ["双层纠偏架构(实时+会后)", "RealtimeReviser实时纠偏器(revision.py)", "DashScope LiveTranslate provider封装(realtime.py)", "四格式报告生成(report.py)", "Tauri桌面悬浮窗+WASAPI采集", "handoff token投送机制", "多源输入PCM采集+WS推流模式"]
non_reusable_parts: ["pipeline.py文本处理逻辑(1788行过度耦合需拆分)", "进程内会话状态(无持久化)", "CORS全放开默认配置", "docs/中无关项目计划文档"]
scores:
  product: 5
  architecture: 3
  engineering: 2
  reuse: 4
  commercialization: 3
evidence:
  - "backend/app/main.py:8-27 (FastAPI应用工厂+CORS+路由注册)"
  - "backend/app/services/pipeline.py:125-180 (InterpretationPipeline核心类,1788行单文件)"
  - "backend/app/services/pipeline.py:472-492 (_bind_response FIFO response_id绑定抵抗译文滞后)"
  - "backend/app/services/pipeline.py:1659-1711 (_on_segment_complete→_run_review→_apply_revision实时纠偏)"
  - "backend/app/services/revision.py:64-90 (RealtimeReviser:限速6次/分+窗口4句+置信度0.62)"
  - "backend/app/services/revision.py:40-61 (build_realtime_revision_prompt领域差异化PROMPT)"
  - "backend/app/services/report.py:25-46 (build_final_correction_prompt会后全局校正)"
  - "backend/app/api/ws.py:46-150 (session_socket WebSocket路由+token校验+finalize)"
  - "backend/app/services/providers/dashscope/realtime.py:47-119 (LiveTranslateSession单WS完成ASR+翻译+TTS)"
  - "backend/app/services/handoff.py:46-80 (HandoffTokenStore issue/claim/300s TTL)"
  - "backend/app/services/session_store.py:1-7 (进程内会话状态,模块文档声明单机部署)"
  - "backend/app/core/config.py:10-91 (pydantic Settings配置管理)"
  - "desktop/src-tauri/src/main.rs:66-100 (Tauri透明置顶窗+权限放行+WASAPI)"
  - "desktop/src-tauri/src/audio_capture.rs:58-78 (WASAPI loopback 16k PCM采集)"
  - "README.md:80-81 (模型策略UI占位未接入真实provider路由)"
  - "README.md:176-184 (四格式报告导出说明)"
confidence: "高"
```
