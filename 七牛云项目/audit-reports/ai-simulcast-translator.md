# ai-simulcast-translator 项目审查报告

## 一句话判断

一款 macOS Electron 同声传译桌面应用，核心创新 Semantic Rewind（字幕作为可收敛的时间线，MiMo 基于后文语义回溯修订最近 5 句/20 秒内字幕，超出窗口锁定）设计精巧；采用 pnpm monorepo + DDD 四层分层（contracts/domain/application/infrastructure），43 个测试文件覆盖跨进程契约与 Python ASR Worker，工程质量在桌面应用类项目中突出。

## 项目地图

- **语言/框架**：Electron + React（渲染层）+ TypeScript（strict + `exactOptionalPropertyTypes` + `noUncheckedIndexedAccess`）+ Python 3.12（ASR Worker）
- **核心依赖**：faster-whisper（本地 ASR）、MiMo（OpenAI-compatible Chat Completions）、pnpm 11.5.2 monorepo、zod（跨进程 schema 校验）、vitest（TS 测试）、pytest（Python 测试）
- **入口**：`apps/desktop/src/main/index.ts`（Electron 主进程，290 行）
- **目录边界**：
  - `apps/desktop/` — Electron 主进程 / preload / React 控制窗 + 悬浮字幕窗 / e2e
  - `packages/contracts/` — IPC、ASR、字幕快照等跨进程契约 + zod schema
  - `packages/domain/` — 字幕时间线、修订窗口、修订引擎、片段状态规则（纯领域，无 I/O）
  - `packages/application/` — 翻译请求构建、快照应用、字幕协调器（端口 + 编排）
  - `packages/infrastructure/` — MiMo 客户端、Whisper Worker 适配器、响应 schema、同语言透传
  - `workers/asr/` — Python ASR Worker（faster-whisper 引擎 + mock 引擎 + JSON-lines 协议）
- **部署形态**：macOS 13+（建议 14.2+）Electron 桌面应用；打包时 `workers/asr` 作为 extra resources 带入
- **规模**：TS/TSX 约 9377 行，Python 约 1581 行，43 个测试文件

## 产品与商业场景

- **目标用户**：观看英语演讲、技术分享、国际会议、网课的中文用户（事实，README:3）
- **核心闭环**：采集 macOS 系统音频 → AudioWorklet 转 16kHz 单声道 PCM → preload 安全 IPC → Electron 主进程 → Python faster-whisper 本地 ASR → MiMo 翻译协调器 → 版本化字幕时间线（Semantic Rewind）→ 透明悬浮窗显示中文字幕 + 英文原文
- **独特价值**：Semantic Rewind — 字幕不是一次性文本流，而是一条可收敛的时间线。MiMo 基于后文语义回溯修订最近 5 句或 20 秒内的字幕；超出窗口的内容锁定，避免用户已读字幕持续跳动（事实，README:5-6；revision-window.ts:23-26）
- **打动评委的瞬间**：播放包含指代、术语、后文反转的英文内容，观察最近字幕原位修订并高亮（事实，README:151）
- **商业化**：付费方为个人 Mac 用户；竞品少（系统级音频采集 + 本地 ASR + 语义修订组合罕见）；差异化明显但平台受限（合理推断）

## 架构拆解

```
macOS 系统音频
  │  getDisplayMedia({audio:true, video:true}) → 丢弃 video track
  ▼
Renderer AudioCapture (audio-capture.ts)
  │  AudioWorklet(pcm-processor) → Int16Array 16kHz mono
  ▼
preload 安全 IPC (preload/index.ts)
  │  contextBridge.exposeInMainWorld("api") + encodePcm16 base64
  │  ipcRenderer.invoke("asr.session.start") / ipcRenderer.send("asr.audio")
  ▼
Electron Main: AsrSessionController (asr-session-controller.ts)
  │  generation 计数器防陈旧启动 + StartupContext.canceled 清理
  ▼
WhisperWorkerAdapter (whisper-worker-adapter.ts)
  │  spawn("uv run python -m asr_worker.main") + stdin/stdout JSON-lines
  │  startup timeout 5s + stdout 行缓冲 + ready/error/exit 事件
  ▼
Python ASR Worker (workers/asr/main.py → faster_whisper_engine.py)
  │  RollingAudioBuffer(max 4000ms) + 首次 1000ms/后续 400ms 触发推理
  │  condition_on_previous_text=False, vad_filter=True, beam_size=1, temperature=0.0
  │  confidence = exp(avg_logprob) clamp [0,1]
  ▼
Electron Main: SubtitleSessionBridge (subtitle-session-bridge.ts)
  │  每 sessionId 独立 timeline + coordinator + rawWindows
  │  ASR transcript → coordinator.submit → 翻译 → applySubtitleSnapshot → publish
  ▼
SubtitleTranslationCoordinator (subtitle-coordinator.ts)
  │  requestId 单调递增 + latestAppliedRequestId 水位线
  │  minRequestIntervalMs=1200ms 节流 + in-flight 单槽队列
  │  翻译返回: applied / stale(requestId≤水位线) / failed
  ▼
TranslatorPort (translator-factory.ts)
  │  LanguageAwareTranslator 包装:
  │    源==目标 → SameLanguageTranslator 透传
  │    MiMo 配置 → MimoClient(OpenAI-compatible, timeout 10s, 格式错重试1次)
  │    未配置/失败 → SourceTextFallbackTranslator(原文当译文)
  │  coordinator 失败 → createFallbackSnapshot(原文当译文)
  ▼
applySubtitleSnapshot (apply-subtitle-snapshot.ts)
  │  applyRevisionWindow 锁定过期段 → snapshot.requestId ≤ lastApplied → stale
  │  按 index 对齐 editableSegments: 新增 insert / 已有 revise
  │  变更带 highlightUntilMs(700ms) 供 UI 高亮
  ▼
版本化字幕时间线 (domain/timeline.ts + segment.ts + revision-window.ts)
  │  SegmentState: live → revisable → locked
  │  每次更新 revisionCounter++ + sourceVersion/translationVersion++
  ▼
Electron 悬浮字幕窗 (renderer app.tsx OverlayWindow)
  │  onSubtitleSnapshot IPC → SubtitleStore.replaceSegments + applyChanges
  │  getVisibleLines({maxLines:3}) → SubtitleLine 渲染(高亮)
```

**核心调用链追踪（一次 ASR transcript 的完整旅程）**：

1. Python Worker 产出 `ResultMessage`（faster_whisper_engine.py:156-166，`is_final=False` 滚动推理）
2. `WhisperWorkerAdapter._handleMessage` 解析 JSON → emit("result", message)（whisper-worker-adapter.ts:262-263）
3. `AsrSessionController.handleResult` 严格字段校验后 publish AsrEvent（asr-session-controller.ts:56-87）
4. 主进程 `index.ts:259-264` publish 到所有窗口 + `subtitleBridge.handleAsrEvent`（index.ts:261）
5. `SubtitleSessionBridge.handleTranscript`（subtitle-session-bridge.ts:93-144）：
   - 更新 `detectedSourceLanguage`（auto 模式，概率≥0.5）
   - 追加 `rawTranscriptWindows`（按 sequence 去重排序）
   - `coordinator.submit` → started 则 await result → `applyCoordinatorResult`
6. `coordinator.translate`（subtitle-coordinator.ts:189-218）：调 `translator.translate`，`snapshot.requestId <= latestAppliedRequestId` 判 stale
7. `applySnapshot`（subtitle-session-bridge.ts:257-288）：调 `applySubtitleSnapshot` → publish `SubtitleSnapshotEvent`
8. OverlayWindow `onSubtitleSnapshot`（app.tsx:447-458）→ `store.replaceSegments` + `applyChanges` + `getVisibleLines`

**三层降级链**（合理推断，由代码证实）：
- L1：源语言==目标语言 → `SameLanguageTranslator` 透传（same-language-translator.ts:29-37）
- L2：MiMo 配置完整 → `MimoClient`；`MimoResponseFormatError` 重试 1 次（mimo-client.ts:67-73）
- L3：MiMo 未配置 → `SourceTextFallbackTranslator`（translator-factory.ts:33-35）
- L4：coordinator 翻译失败 → `createFallbackSnapshot`（subtitle-session-bridge.ts:207-212, 316-328）—— 原文当译文，不中断演示

## 工程评分（1-5）

| 维度 | 分数 | 证据 |
|------|------|------|
| 产品完成度 | 4 | 系统音频采集 + 本地 ASR + Semantic Rewind + 悬浮窗，功能完整可演示（README:12-20） |
| 架构边界 | 5 | monorepo 四层（contracts/domain/application/infrastructure）职责单向依赖，domain 无 I/O（packages/domain 仅 import 自身） |
| 可维护性 | 5 | 分层 + 跨进程契约 + 端口/适配器（TranslatorPort/AsrWorkerPort），替换 MiMo 或 ASR 引擎不影响 domain |
| 可测试性 | 5 | 43 个测试文件；asr-session-controller.test.ts(506行)、whisper-worker-adapter.test.ts(374行)、subtitle-coordinator.test.ts(236行)；Python pytest；E2E + verify:demo |
| 可观测性 | 4 | requestId 水位线丢弃过期响应（subtitle-coordinator.ts:194）；stderr 打印 Worker 错误；但缺少结构化日志/指标 |
| 安全隐私 | 5 | contextIsolation+nodeIntegration:false+sandbox:true（index.ts:54-59）；will-navigate 策略（index.ts:70-86）；API Key 仅主进程（translator-factory 在 main）；音频不落盘（README:155） |
| 性能并发 | 4 | 本地 ASR 零 API 成本；1200ms 节流防过载；但单槽队列（非真队列）可能丢中间 transcript（subtitle-coordinator.ts:96,112） |
| 资源释放 | 4 | before-quit 清理（index.ts:269-272）；AsrSessionController.dispose 解绑+stop；AudioCapture.releaseResources 闭 stream/context |
| 成本控制 | 5 | faster-whisper 本地 ASR 零 API 成本；MiMo 仅翻译 + 修订，token 受 20s 窗口约束 |
| 部署恢复 | 3 | 仅 macOS 13+；需系统音频/屏幕录制权限；打包带 Python worker 为 extra resources |
| 文档 | 4 | README + docs/demo.md（降级/真实/Rewind/30 分钟检查/CI 覆盖）+ docs/superpowers 15 个 PR 计划 + 2 个设计 spec |
| 上手难度 | 3 | 需 macOS 13+ + Node 22+ + Python 3.12 + pnpm 11.5.2 + uv，环境门槛较高 |

## 优点

1. **Semantic Rewind 时间线创新**（事实）：字幕作为可收敛时间线而非一次性文本流。`SegmentState: live → revisable → locked`（segment.ts:6），修订窗口 `maxSentences=5, maxTimeMs=20000`（revision-window.ts:23-26），超出窗口锁定避免已读字幕跳动。每次更新 `revisionCounter++` + `sourceVersion/translationVersion++`（timeline.ts:81-96），修订引擎校验 `expectedVersion` 匹配（revision-engine.ts:134-139）。解决了实时翻译"后文反转/指代消解"的核心体验问题。

2. **monorepo DDD 四层分层**（事实）：`contracts`（跨进程契约 + zod schema）→ `domain`（纯领域，timeline/segment/revision-window/revision-engine，无 I/O 依赖）→ `application`（端口 TranslatorPort + 协调器编排）→ `infrastructure`（MimoClient/WhisperWorkerAdapter 实现）。domain 层完全不 import infrastructure，端口/适配器模式使替换 MiMo 或 ASR 引擎不影响领域逻辑。在桌面应用中罕见且专业。

3. **requestId 水位线丢弃过期响应**（事实）：`SubtitleTranslationCoordinator` 维护 `latestAppliedRequestId`（subtitle-coordinator.ts:93），翻译返回时 `snapshot.requestId <= latestAppliedRequestId` 判 stale（subtitle-coordinator.ts:194-201），`applySubtitleSnapshot` 同样校验（apply-subtitle-snapshot.ts:75-84）。防止异步竞态中旧快照覆盖新字幕。

4. **完整测试体系**（事实）：43 个测试文件覆盖跨进程契约（contracts/*.test.ts）、领域规则（domain/*.test.ts）、协调器（subtitle-coordinator.test.ts 236 行）、ASR 控制器（asr-session-controller.test.ts 506 行）、Worker 适配器（whisper-worker-adapter.test.ts 374 行）、Python ASR（test_faster_whisper_engine.py 348 行）。`pnpm ci` = format + lint + typecheck + test + build + e2e + verify:demo 同等验证（package.json:11）。

5. **Electron 安全实践**（事实）：`contextIsolation:true, nodeIntegration:false, sandbox:true`（index.ts:54-59）；`will-navigate` 经 `decideNavigation` 策略（index.ts:70-86）；`window.open` 一律 deny，外部链接走 `shell.openExternal`（index.ts:62-68）；API Key 仅主进程 `createTranslatorFromEnv(process.env)` 读取（index.ts:252），不暴露给 renderer；preload 仅暴露最小 API（preload/index.ts:76-139）。

6. **faster-whisper 本地 ASR 零成本 + 确定性推理**（事实）：`condition_on_previous_text=False, vad_filter=True, beam_size=1, temperature=0.0, best_of=1`（faster_whisper_engine.py:112-117）—— 确定性、低延迟、防幻觉累积；`RollingAudioBuffer` 滑窗 max 4000ms（faster_whisper_engine.py:26,56-59），首次 1000ms 触发、后续 400ms 步进（faster_whisper_engine.py:92-98）；`confidence=exp(avg_logprob)` clamp（faster_whisper_engine.py:151-154）；模型懒加载（faster_whisper_engine.py:178-185）。

7. **ASR Worker 进程隔离与陈旧启动防护**（事实）：`WhisperWorkerAdapter` spawn 子进程，stdin/stdout JSON-lines，startup timeout 5s（whisper-worker-adapter.ts:180），stdout 行缓冲 + StringDecoder（whisper-worker-adapter.ts:237-247）；`AsrSessionController` 用 `startupGeneration` 计数器 + `StartupContext.canceled` 标志，使 `stop`/`dispose` 后的陈旧启动回调被识别并丢弃（asr-session-controller.ts:52,166,197-202,297-302）。

## 缺点、风险与改进优先级

| 级别 | 问题 | 证据/影响 | 修复方向 |
|------|------|-----------|----------|
| P1 | 仅限 macOS | 系统音频采集依赖 `getDisplayMedia` + macOS 权限（audio-capture.ts:71-75）；README:46 限定 macOS 13+ | 跨平台方案（Windows WASAPI loopback / Linux PulseAudio monitor）或明确产品定位 |
| P2 | MimoClient 仅对 `MimoResponseFormatError` 重试，网络错误不重试 | mimo-client.ts:67-73：`if (!(error instanceof MimoResponseFormatError)) throw error` | 对超时/5xx 增加有限重试 + 指数退避 |
| P2 | 单槽队列（非真队列）可能丢中间 transcript | subtitle-coordinator.ts:96,112：in-flight 时 `queuedInput = input` 直接覆盖，多次到达只保留最后 | 改为合并（merge rawWindows）或真队列 |
| P2 | 新增 segment 时间戳用 `currentAudioTimeMs` 占位 | apply-subtitle-snapshot.ts:101-106：`addSegment(..., currentAudioTimeMs, currentAudioTimeMs)` start==end | 用 snapshot item 携带的 startMs/endMs（需扩展 schema） |
| P2 | MiMo 超时 10s 可能偏紧 | mimo-client.ts:58 `timeoutMs ?? 10_000`；长上下文 + 修订可能超时 | 区分首句/修订超时，或提到 15-20s |
| P3 | License 未确定 | README:162 "默认保留所有权利" | 添加明确 License（MIT/Apache-2.0） |
| P3 | 环境门槛高 | Node 22+/pnpm 11.5.2/Python 3.12/uv + macOS 权限 | 提供 Docker/devcontainer 或一键脚本 |
| P3 | `.env.example` 与 README 模型默认值不一致 | README:84 `WHISPER_MODEL=small.en`；.env.example `WHISPER_MODEL=small`；`.en` 模型强制英语（faster_whisper_engine.py:48-53 校验） | 统一默认值并文档化多语言场景 |
| P3 | 缺少结构化日志/指标 | 多处 `console.error`（index.ts:43,91,99；whisper-worker-adapter.ts:155） | 引入结构化日志 + 关键指标（ASR 延迟/翻译延迟/stale 率） |

## 复用性矩阵

| 维度 | 分数 | 说明 |
|------|------|------|
| 技术复用 | 5 | Semantic Rewind 时间线 + 修订窗口 + 四层分层 + 端口/适配器可直接复用 |
| 产品复用 | 3 | macOS 同声传译场景明确但平台受限 |
| 商业复用 | 3 | Mac 个人用户付费意愿中等，差异化明显但用户基数有限 |

- **可直接复用**：
  - Semantic Rewind 时间线 + 修订窗口 + 三态 segment 模式（`packages/domain`）—— 任何"可回溯修订的流式输出"场景（会议纪要、实时字幕、直播弹幕修正）
  - monorepo DDD 四层分层骨架（contracts/domain/application/infrastructure）
  - `SubtitleTranslationCoordinator` 的 requestId 水位线 + 节流 + 单槽队列 + stale 判定模式
  - Electron 安全 IPC + 主进程密钥隔离 + will-navigate 策略
  - faster-whisper 滚动推理 Worker（RollingAudioBuffer + 确定性推理参数）
  - `AsrSessionController` 的 generation 计数器防陈旧启动模式
- **改造后复用**：MiMo 客户端可泛化为任意 OpenAI-compatible 翻译；Python ASR Worker 协议可对接其他 ASR 引擎
- **不应复用**：macOS `getDisplayMedia` 系统音频采集绑定；悬浮窗 UI 布局

## 值得学习的内容

1. **Semantic Rewind：可收敛时间线设计**（进阶者）：`packages/domain` — 字幕不是一次性文本流而是可回溯修订的时间线，三态生命周期（live/revisable/locked）+ 修订窗口（最近 N 句或 T 毫秒）+ 版本号校验。核心思想：实时输出允许"先快后准"，但必须有一个"锁定点"让已读内容稳定。可迁移到任何流式 AI 输出场景。

2. **requestId 水位线丢弃过期响应**（可迁移）：`subtitle-coordinator.ts:194` — 异步竞态中用单调递增 requestId + `latestAppliedRequestId` 水位线，拒绝旧响应覆盖新状态。比简单的"最后到达胜出"更安全，也比全局锁更轻量。

3. **monorepo DDD 四层分层 + 端口/适配器**（进阶者）：`packages/` — contracts（契约）/domain（纯领域无 I/O）/application（端口+编排）/infrastructure（实现）。domain 不依赖 infrastructure，替换 MiMo/ASR 引擎不影响领域逻辑。在桌面应用中实践 DDD 的范本。

4. **ASR Worker 进程隔离 + 陈旧启动防护**（可迁移）：`asr-session-controller.ts` — `startupGeneration` 计数器 + `StartupContext.canceled` 标志，使 stop/dispose 后的陈旧启动回调被识别丢弃。比简单的"取消 Promise"更鲁棒。

5. **faster-whisper 确定性滚动推理**（可迁移）：`faster_whisper_engine.py` — `condition_on_previous_text=False`（防幻觉累积）+ `temperature=0.0/beam_size=1`（确定性）+ `vad_filter=True`（静音过滤）+ RollingAudioBuffer 滑窗 + 首次/后续差异化触发阈值。

6. **Electron 安全 IPC 最小暴露面**（初学者）：`preload/index.ts` + `index.ts:54-86` — contextIsolation+sandbox+nodeIntegration:false 三件套 + will-navigate 策略 + window.open deny + API Key 仅主进程 + preload 仅暴露最小 API。

## 结构化摘要

```yaml
project: ai-simulcast-translator
one_line_judgment: "macOS Electron同声传译桌面应用，Semantic Rewind字幕时间线可回溯修订+monorepo DDD四层分层+43测试文件，工程质量突出"
product_type: "桌面应用/同声传译"
target_users: ["观看英语演讲/技术分享/国际会议/网课的中文用户"]
core_loop: "采集macOS系统音频 -> AudioWorklet转16kHz PCM -> Python faster-whisper本地ASR -> MiMo翻译协调器 -> 版本化字幕时间线(Semantic Rewind回溯修订+窗口锁定) -> 透明悬浮窗显示"
architecture_style: "Electron桌面应用 + pnpm monorepo DDD四层分层(contracts/domain/application/infrastructure) + Python ASR Worker子进程 + 端口/适配器"
stack: ["Electron", "React", "TypeScript(strict+exactOptionalPropertyTypes)", "pnpm monorepo", "Python3.12", "faster-whisper", "MiMo(OpenAI-compatible)", "zod", "vitest", "pytest"]
strongest_patterns:
  - "Semantic Rewind(字幕三态live/revisable/locked时间线+修订窗口5句/20s+版本号校验+超出窗口锁定)"
  - "requestId水位线丢弃过期响应(latestAppliedRequestId防异步竞态)"
  - "monorepo DDD四层分层(domain无I/O+端口/适配器TranslatorPort/AsrWorkerPort)"
  - "三层降级链(同语言透传->MiMo格式错重试1次->SourceTextFallback->coordinator失败FallbackSnapshot)"
  - "ASR Worker进程隔离+startupGeneration计数器防陈旧启动"
  - "faster-whisper确定性滚动推理(condition_on_previous_text=False+temperature0+beam1+vad_filter+RollingAudioBuffer)"
  - "Electron安全IPC(contextIsolation+sandbox+will-navigate策略+API Key仅主进程)"
  - "完整测试体系(43测试文件+pnpm ci同等验证+verify:demo+pytest)"
main_risks:
  - "P1:仅限macOS,系统音频采集依赖macOS API"
  - "P2:MimoClient仅对格式错误重试,网络错误不重试"
  - "P2:单槽队列非真队列,多次in-flight期间transcript只保留最后"
  - "P2:新增segment时间戳用currentAudioTimeMs占位,start==end"
  - "P3:License未确定/环境门槛高/.env模型默认值不一致/缺结构化日志"
business_scenarios: ["实时同声传译", "英语字幕辅助", "会议/网课翻译", "可回溯修订的流式AI输出(泛化)"]
reusable_assets:
  - "Semantic Rewind时间线+修订窗口+三态segment模式(packages/domain)"
  - "SubtitleTranslationCoordinator(requestId水位线+节流+stale判定)"
  - "monorepo DDD四层分层骨架"
  - "Electron安全IPC+主进程密钥隔离+will-navigate策略"
  - "faster-whisper确定性滚动推理Worker"
  - "AsrSessionController generation计数器防陈旧启动"
non_reusable_parts: ["macOS getDisplayMedia系统音频采集绑定", "悬浮字幕窗UI布局"]
scores:
  product: 4
  architecture: 5
  engineering: 5
  reuse: 5
  commercialization: 3
evidence:
  - "README.md:5-6(Semantic Rewind定义)"
  - "README.md:36-42(monorepo四层模块)"
  - "README.md:113-131(验证命令+pnpm ci同等)"
  - "README.md:153-158(数据隐私)"
  - "packages/domain/src/subtitle/segment.ts:6(SegmentState三态)"
  - "packages/domain/src/subtitle/revision-window.ts:23-26(修订窗口5句/20s)"
  - "packages/domain/src/subtitle/revision-window.ts:34-62(锁定规则)"
  - "packages/domain/src/subtitle/timeline.ts:81-96(版本号递增)"
  - "packages/domain/src/revision/revision-engine.ts:134-139(expectedVersion校验)"
  - "packages/application/src/translation/subtitle-coordinator.ts:92-93,194(requestId水位线)"
  - "packages/application/src/translation/subtitle-coordinator.ts:100,106-127(节流+单槽队列)"
  - "packages/application/src/revision/apply-subtitle-snapshot.ts:75-84,101-106(stale判定+时间戳占位)"
  - "packages/infrastructure/src/mimo/mimo-client.ts:58,67-73(timeout10s+仅格式错重试)"
  - "packages/infrastructure/src/asr/whisper-worker-adapter.ts:180,237-247(startup timeout+行缓冲)"
  - "apps/desktop/src/main/asr/asr-session-controller.ts:52,166,297-302(generation防陈旧)"
  - "apps/desktop/src/main/index.ts:54-59,70-86,252(安全IPC+密钥隔离)"
  - "apps/desktop/src/main/subtitle/translator-factory.ts:33-43(三层降级)"
  - "apps/desktop/src/main/subtitle/subtitle-session-bridge.ts:207-212,316-328(FallbackSnapshot)"
  - "workers/asr/src/asr_worker/faster_whisper_engine.py:92-98,112-117,151-154(滚动推理+确定性参数+confidence)"
  - "tsconfig.base.json(strict+exactOptionalPropertyTypes+noUncheckedIndexedAccess)"
confidence: "高"
```
