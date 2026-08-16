# Sayit 审查报告

## 一句话判断

基于 Android InputMethodService 的语音输入法，以悬浮球+方向手势为核心交互创新，将流式 ASR 与 LLM 翻译/问答融合到任意输入框中，完成度和体验设计突出，但存在严重的 API 密钥泄露问题和测试缺失。

## 项目地图

| 维度 | 信息 |
|------|------|
| 项目名称 | Sayit 你说 |
| 类型 | Android 原生应用（输入法 IME） |
| 语言/框架 | Kotlin / Android InputMethodService |
| 构建工具 | Gradle 8.13.2 + Kotlin 2.2.20 |
| SDK | minSdk 26, targetSdk 34, compileSdk 34, JVM 17 |
| 源码规模 | 21 个 Kotlin 文件，约 6,133 行（含重复计数） |
| 核心入口 | `VoiceKeyboard.kt`（IME Service） |
| 外部服务 | 火山引擎流式 ASR（WebSocket）、OpenAI 兼容 LLM（SSE） |
| 仓库状态 | 1 次 git commit（项目刚提交） |

**目录结构（主要源码）：**
```
app/src/main/java/org/sayit/voiceime/
├── VoiceKeyboard.kt          # IME 核心：ASR WebSocket、overlay、insets、提交文本（1075行）
├── SettingsActivity.kt       # 设置页（449行）
├── AppSettings.kt            # SharedPreferences / BuildConfig 配置（94行）
├── PermissionActivity.kt     # 权限引导（68行）
├── action/GestureActionHandler.kt  # 手势处理+删除恢复栈（175行）
├── api/LLMService.kt         # LLM SSE 流式调用（148行）
├── clipboard/                # 剪贴板历史（3文件）
├── gesture/GestureAction.kt  # 手势事件定义（26行）
├── overlay/                  # 结果气泡、窗口辅助（2文件）
└── widget/                   # 悬浮球、轮盘、符号面板、手势引导（6文件）
```

## 产品与商业场景

**目标用户：** 微信/QQ/短信聊天用户、邮件/文档起草者、多语言沟通者、单手/大屏手机用户、无障碍需求用户。

**场景痛点：** 传统语音输入法仅有"按住说话→转文字"单一模式，切换翻译/问答需退出输入框另开 App；全键盘 IME 占据半屏，遮挡内容；单手操作时删字、改错困难。

**输入/处理/输出/反馈闭环：**
- 输入：长按悬浮球开始录音（16kHz PCM），录音中滑动方向选择模式
- 处理：PCM 通过 WebSocket 推送火山 ASR 流式识别；松手后按 VoiceMode 分流（直接提交/LLM 翻译/LLM 问答/发送）
- 输出：识别文本通过 InputConnection.commitText 写入宿主输入框
- 反馈：结果气泡实时展示流式增量；composing 预览在输入框实时更新

**独特价值：** 同一长按流程内用方向手势切换取消/问答/翻译/发送四种模式，无需额外按钮或模式切换页；悬浮球 overlay 与 IME 解耦，IME 占位趋近于零。

**商业化分析：**
- 付费方：终端用户（高级 LLM 功能付费）或手机厂商预装
- 获客渠道：应用商店 + B站演示视频
- 交付成本：需用户自备 ASR/LLM API Key（或内置转发），配置门槛较高
- 持续使用理由：一旦习惯方向手势，回退传统输入法效率下降明显

## 架构拆解

### 文字架构图

```
用户应用输入框
    ↑ commitText / setComposingText / performEditorAction
VoiceKeyboard (InputMethodService, 占位趋近0)
    ↑ 手势事件 / 状态回调
FloatingBallView (SYSTEM_ALERT_WINDOW overlay)
    ├─ 长按 → AudioRecord(16kHz PCM) → WebSocket → 火山ASR（流式识别）
    │         ↓ 二进制协议帧（自定义4字节头+payload）
    │         ↓ processRecognitionJson → setComposingText + resultBuffer
    │
    ├─ 松手+方向手势 → GestureActionHandler → VoiceMode 分流
    │   ├─ INPUT    → commitText(resultBuffer)
    │   ├─ QUESTION → LLMService.askStreaming(SSE) → ResultBubble
    │   ├─ TRANSLATE→ LLMService.translateStreaming(SSE) → ResultBubble
    │   └─ SEND     → commitText + performEditorAction
    │
    ├─ 非录音左滑 → 逐字删除(LIFO栈) → 右滑恢复
    │
    └─ 单击 → RadialMenuView（设置/剪贴板/符号面板/切换IME）
```

### 请求追踪：一条完整的语音翻译请求

1. 用户长按悬浮球 → `FloatingBallView` 发出 `LongPressStart` → `GestureActionHandler.handle()` → `ime.startVoiceInput()` → `startSpeechRecognition()`（`VoiceKeyboard.kt:468`）
2. `connectToASR()`（`VoiceKeyboard.kt:776`）建立 WebSocket，发送 `buildFullClientRequestPayload()` 配置 ASR 参数
3. `startRecording()`（`VoiceKeyboard.kt:830`）循环读取 PCM，按二进制协议帧 `buildBinaryFrame()` 推送
4. 用户左滑 → `GestureAction.Swipe(LEFT)` → `currentVoiceMode = TRANSLATE`（`GestureActionHandler.kt:60`）
5. 用户松手 → `SwipeComplete` → `ime.stopVoiceInputWithMode(TRANSLATE)` → `stopSpeechRecognition()`
6. 录音协程进入 300ms grace period 继续发送尾部音频，发送结束包，等待 `taskFinished`
7. `deliverSpeechResults()`（`VoiceKeyboard.kt:495`）按 `VoiceMode.TRANSLATE` 调用 `llmService.translateStreaming()`
8. `LLMService.streamChat()`（`LLMService.kt:55`）通过 SSE EventSource 接收增量，`onDelta` 回调更新 `ResultBubbleView`
9. `ResultBubbleView.onInsert` 回调将完整结果 `commitText` 到输入框

### 关键设计决策

- **二进制协议帧处理**（`VoiceKeyboard.kt:970-1003`）：自定义 4 字节头 + payload 大小 + payload，支持 GZIP 压缩和序列号，直接对接火山 ASR 二进制协议
- **IME 占位趋零**（`VoiceKeyboard.kt:333-342`）：`onEvaluateFullscreenMode()=false`，`onComputeInsets` 仅在有符号面板时抬高 inset
- **删除恢复栈**（`GestureActionHandler.kt:26-27, 130-144`）：ArrayDeque 实现 LIFO 栈，左滑逐字删除入栈，右滑出栈恢复

## 工程评分

| 维度 | 分数 | 证据 |
|------|------|------|
| 产品完成度 | 4 | 10 项原创功能均有实现代码，ASR+LLM+手势+剪贴板+符号面板闭环完整 |
| 架构边界 | 3 | 模块划分合理（action/api/clipboard/gesture/overlay/widget），但 VoiceKeyboard 1075 行承担过多职责 |
| 可维护性 | 3 | 代码可读，命名清晰，但缺少文档注释和架构图；VoiceKeyboard 是上帝类 |
| 可测试性 | 1 | 无任何测试代码；IME+overlay 高度耦合系统 API，难以单元测试 |
| 可观测性 | 2 | 有 Log.d/Log.e 日志，但无结构化日志、无崩溃上报、无性能指标 |
| 安全隐私 | 1 | **local.properties 含明文 ASR/LLM API Key 且被 git 追踪**（阻断级问题） |
| 性能并发 | 3 | 协程+volatile 状态管理合理；AudioRecord 在 IO 线程；WebSocket 非阻塞 |
| 资源释放 | 3 | onDestroy 中释放 audioRecord/webSocket/overlay/receiver，但 `ws?.cancel()` 延迟 3s 在 scope.cancel 后可能不执行 |
| 成本控制 | 2 | LLM max_completion_tokens=1024 合理，但无缓存、无用量统计、无离线降级 |
| 部署恢复 | 2 | gradlew installDebug 可安装，但需用户手动配置密钥和系统权限 |
| 文档 | 3 | README 详尽（功能、手势、架构、安装），但缺 TEST_GUIDE.md（README 引用了但仓库中不存在） |
| 上手难度 | 3 | 需 Android 开发环境+火山 ASR+LLM API，门槛中高 |

### 问题分级

**阻断级：**
- `local.properties` 含明文 ASR API Key（`c4e4ba1e-...`）和 LLM API Key（`sk-c50r2...`），且被 git 追踪（`git ls-files` 确认 tracked）。.gitignore 文件为空。整个 `app/build/` 构建缓存目录也被 git 追踪。（`local.properties:15-20`, `.gitignore` 为空）

**重要级：**
- 无任何测试代码（0 个测试文件），核心 ASR 协议帧解析、手势状态机、删除恢复栈均无覆盖
- `VoiceKeyboard.kt` 1075 行，承担 ASR 连接/录音/协议解析/overlay 管理/面板管理/文本提交全部职责，是上帝类
- release 构建未开启混淆（`isMinifyEnabled = false`，`build.gradle.kts:73`）

**一般级：**
- README 引用 `TEST_GUIDE.md` 但文件不存在
- `LLMService.kt:59` 使用 `api-key` header 而非标准 `Authorization: Bearer`，对部分 OpenAI 兼容接口可能不兼容
- `deliverSpeechResults()` 中 `scope.launch { delay(3000); ws?.cancel() }` 在 `onDestroy` 的 `scope.cancel()` 后不会执行

**建议级：**
- 考虑将 ASR 协议帧编解码提取为独立类，便于测试和复用
- 剪贴板历史未加密存储，敏感内容可能泄露
- 缺少权限拒绝后的引导重试逻辑

## 优点

1. **悬浮球+超低 IME 占位**：输入 UI 与系统键盘解耦的设计在同类产品中少见，主交互在 overlay 完成，宿主仅保留极薄占位（`VoiceKeyboard.kt:333-342`）
2. **录音方向手势多模态**：同一长按流程内用上/下/左/右滑切换取消/问答/翻译/发送，交互设计精巧（`GestureActionHandler.kt:53-91`）
3. **句末 grace 音频**：松手后额外 300ms 继续上传音频并发送结束包，降低截断尾音漏字（`VoiceKeyboard.kt:864-880`）
4. **左滑渐进删除+右滑 LIFO 恢复**：滑动标尺删字与可逆恢复，适配单手快速改错（`GestureActionHandler.kt:109-145`）
5. **SSE 流式 LLM 响应**：翻译/问答结果通过结果气泡实时展示增量，体验流畅（`LLMService.kt:74-127`）
6. **二进制协议帧完整实现**：火山 ASR 的自定义二进制协议（4字节头+GZIP+序列号）编解码正确（`VoiceKeyboard.kt:970-1003`）

## 缺点风险与改进优先级

| 优先级 | 问题 | 影响 | 建议 |
|--------|------|------|------|
| P0 | API Key 泄露 | 密钥被盗用、产生费用 | 立即从 git 历史移除 local.properties，轮换密钥，添加 .gitignore |
| P0 | app/build/ 被追踪 | 仓库膨胀、潜在信息泄露 | git rm --cached app/build/，添加到 .gitignore |
| P1 | 零测试 | 核心逻辑无回归保护 | 为协议帧解析、手势状态机、删除恢复栈编写单元测试 |
| P1 | VoiceKeyboard 上帝类 | 可维护性差 | 拆分为 ASRManager + OverlayManager + PanelManager |
| P2 | release 未混淆 | APK 易逆向 | 开启 isMinifyEnabled + ProGuard 规则 |
| P2 | 剪贴板明文存储 | 敏感信息泄露 | 加密存储或提供禁用选项 |
| P3 | 缺少 TEST_GUIDE.md | 文档不完整 | 补充联调指南 |

## 复用性矩阵

| 部分 | 评级 | 说明 |
|------|------|------|
| ASR 二进制协议帧编解码 | 可直接复用 | `buildBinaryFrame`/`handleBinaryResponse` 可提取为独立库 |
| 悬浮球+手势交互框架 | 改造后复用 | FloatingBallView/GestureActionHandler 可作为 Android overlay 交互模板 |
| LLM SSE 流式调用 | 可直接复用 | `LLMService.kt` 的 EventSource 封装简洁通用 |
| IME 占位控制 | 可直接复用 | `onComputeInsets` + `onEvaluateFullscreenMode` 方案 |
| 删除恢复栈 | 可直接复用 | LIFO 栈模式可迁移到任何文本编辑器 |
| VoiceKeyboard 整体 | 不应复用 | 上帝类，职责过多 |
| 剪贴板监听 | 改造后复用 | 需加密后再用于生产 |

**复用评分：** 技术 4 / 产品 3 / 商业 2

## 值得学习的内容

1. **【初学者】Android IME 与 overlay 协作模式**：InputMethodService 提供极薄占位，主交互在 SYSTEM_ALERT_WINDOW overlay 完成，是输入法创新的可行路径
2. **【初学者】流式 ASR 的二进制协议实现**：自定义帧头(版本/类型/标志/序列化/压缩) + payload 的编解码是音视频/实时通信领域的通用模式
3. **【进阶者】手势状态机设计**：录音中/非录音中、左滑/右滑/上滑/下滑的状态分支和模式切换，是触摸交互设计的经典案例
4. **【进阶者】IME 生命周期与资源管理**：onCreate/onStartInputView/onWindowHidden/onDestroy 中的 overlay/录音/WebSocket 协程的创建与释放
5. **【可复刻实验】** 基于悬浮球的方向手势多模态交互可迁移到任何需要"一个入口+多种操作"的场景（如翻译球、搜索球）
6. **【可迁移模式】** SSE 流式响应 + 结果气泡的实时展示模式，适用于任何需要展示 LLM 增量输出的场景

```yaml
project: Sayit
one_line_judgment: "基于 Android IME 的悬浮球语音输入法，方向手势多模态交互创新突出，但存在 API 密钥泄露和零测试问题"
product_type: "Android 语音输入法（IME）"
target_users: ["聊天用户", "文档起草者", "多语言沟通者", "单手/大屏用户", "无障碍需求用户"]
core_loop: "长按录音(ASR) → 方向手势选模式 → 流式识别/LLM翻译问答 → commitText写入输入框 → 气泡反馈"
architecture_style: "Android IME + System Overlay 解耦架构"
stack: ["Kotlin", "Android InputMethodService", "OkHttp WebSocket", "OkHttp SSE", "Gson", "Coroutines", "火山引擎ASR", "OpenAI兼容LLM"]
strongest_patterns: ["悬浮球+超低IME占位解耦", "录音方向手势多模态", "左滑渐进删除+LIFO恢复栈", "句末grace音频", "二进制协议帧ASR", "SSE流式LLM"]
main_risks: ["API密钥明文泄露到git", "零测试覆盖", "VoiceKeyboard上帝类1075行", "release未混淆", "app/build被git追踪"]
business_scenarios: ["微信QQ短信语音转文字", "邮件文档听写", "多语言翻译输入", "语音问答", "单手操作", "无障碍辅助"]
reusable_assets: ["ASR二进制协议帧编解码", "LLM SSE流式封装", "悬浮球手势交互框架", "IME占位控制方案", "删除恢复LIFO栈"]
non_reusable_parts: ["VoiceKeyboard整体上帝类", "明文剪贴板存储", "local.properties密钥配置"]
scores:
  product: 4
  architecture: 3
  engineering: 2
  reuse: 4
  commercialization: 2
evidence: ["local.properties:15-20(API Key明文)", "VoiceKeyboard.kt:468-496(ASR启动)", "VoiceKeyboard.kt:776-828(WebSocket连接)", "VoiceKeyboard.kt:830-896(录音+grace)", "VoiceKeyboard.kt:970-1003(协议帧)", "GestureActionHandler.kt:53-91(手势状态机)", "GestureActionHandler.kt:109-145(删除恢复)", "LLMService.kt:55-127(SSE流式)", "build.gradle.kts:73(release未混淆)", ".gitignore(空文件)"]
confidence: "高"
```
