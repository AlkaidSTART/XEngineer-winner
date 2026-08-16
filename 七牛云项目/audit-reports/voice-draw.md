# VoiceDraw 审查报告

## 一句话判断

VoiceDraw 是一个纯语音控制的 AI 绘图工具，自研统一绘图 DSL + 纯函数解释器 + 场景图 + 快照栈，三层指令理解（规则快路径 / LLM 结构化解析 / Agent 创作拆解）配合本地 VAD + 流式 ASR + TTS 闭环，是五个项目里技术原创度最高、测试密度最大、降级链路最完整的一个，个人独立完成且工程素养突出。

---

## 项目地图

- **根目录**：`/Users/allure/Desktop/七牛云项目/voice-draw`
- **语言/运行时**：TypeScript 全栈，Node 20+，pnpm workspace（前后端两个包）
- **两大子模块**：
  1. `backend` — Express + ws，端口 8787，ASR WebSocket 网关 + LLM/TTS 密钥隔离代理
  2. `frontend` — React 18 + Vite，端口 5173，含 NLU/引擎/DSL/freehand/voice 五大子系统
- **入口**：`backend/src/index.ts`（47 行启动）；`frontend/src/main.tsx` → `App.tsx`（855 行）
- **70 个 TS/TSX 文件，13359 行，28 个 .test.ts 测试文件**（测试源码占比约 40%）
- **子系统边界**（`frontend/src/`）：
  - `dsl/` — 绘图 DSL Schema（zod strict），`schema.ts` 526 行
  - `engine/` — 纯函数解释器 + 场景图 + 布局 + 历史快照栈，`interpreter.ts` 1239 行
  - `nlu/` — 三层指令理解（rules/llm/clarify/confirm/correction/planner/orchestrate/speculate），`llm.ts` 481 行
  - `freehand/` — 自由画笔引擎（perfect-freehand + vpath 贝塞尔），`FreehandSceneStage.tsx` 829 行
  - `voice/` — VAD 断句 + ASR FSM + TTS，`useVoice.ts` 259 行
- **后端模块**（`backend/src/`）：`asr/`（火山豆包流式 ASR 网关 + mock + volc-codec）、`llm/`（方舟 doubao-seed 代理）、`tts/`（豆包 TTS 代理）
- **外部服务**：火山引擎豆包流式 ASR + 火山方舟 doubao-seed-2.0-pro LLM + 豆包 TTS 2.0，三级降级（mock / WebSpeech / speechSynthesis）
- **文档**：`docs/` 四份设计文档（架构/交互协议/规则层规格/能力清单）+ `CLAUDE.md` 17KB 开发笔记

---

## 产品与商业场景

- **目标用户**：七牛云 1024 创作节"纯语音绘图"题目参赛场景；延伸到无障碍绘图、儿童语音创作、语音交互 demo
- **场景痛点**：传统绘图依赖鼠标键盘，对视障/儿童/手持设备不友好；纯 LLM 一次生成缺乏可编辑性和事务式 undo/redo
- **闭环**：
  - 输入：麦克风语音 → 本地 Silero VAD 断句（WASM）→ 流式 ASR 转写
  - 处理：三层指令理解（规则快路径 <1ms / LLM 结构化解析 / Agent 多主体拆解）→ 统一 JSON Op
  - 输出：DSL Schema 校验 → 纯函数解释器执行 → 场景图 → freehand 手绘动画渲染
  - 反馈：TTS 语音播报结果/澄清/确认，半双工互斥防自激
- **独特价值**：
  1. 自研统一绘图 DSL + 纯函数解释器，所有理解层输出同一套 Op，天然支持事务式 undo/redo
  2. 流式逐笔渐进出图（边生成边看到笔触），体验优于一次成图
  3. 多主体 Agent 编排：并发 LLM + 串行应用 + 隔离执行消除跨角色串台
  4. 完整降级链：无密钥也能跑（mock ASR + 规则层 + speechSynthesis）
- **打动评委的瞬间**："画一个雪人"→ LLM 拆解 10+ 部件逐笔渐现 + "把雪人往右移很多"整组移动 + "在雪人左边画一棵比它矮的树"相对定位精确落地
- **商业化分析**：
  - 付费方：无障碍产品、儿童教育、语音交互方案演示
  - 获客渠道：创作节 demo + 技术博客 + 开源
  - 交付成本：低（纯前端为主，后端仅密钥代理）
  - 持续使用理由：语音交互新颖性 + 可扩展 DSL
  - 风险：LLM 成本、语音识别准确率、绘图表达力天花板

---

## 架构拆解

```
┌─ Frontend (React/Vite) ─────────────────────────┐
│ voice/useVoice: VAD(Silero WASM) → ASR FSM       │
│   ├ GatewayAsr (ws→backend 火山豆包)              │
│   └ WebSpeechAsr (二级降级)                       │
│ nlu/ 三层理解:                                    │
│   rules (系统指令 <1ms: 撤销/清空/导出)            │
│   correction (同音词纠错: 词表+拼音编辑距离)        │
│   llm (parse/plan/layout 三模式, 流式)            │
│   clarify (歧义澄清: 颜色/位置区分)                │
│   confirm (破坏性操作二次确认)                     │
│   orchestrate (多主体并发编排+隔离执行)            │
│   speculate (partial 投机解析)                    │
│ dsl/schema (zod strict Op 校验)                   │
│ engine/interpreter (纯函数执行, 1239行)            │
│   ├ executeTransaction (事务式, 失败保留已成功)    │
│   ├ resolveTarget (byId/byName/byFocus/byQuery)  │
│   └ 14+ Op: create/style/move/resize/rotate/     │
│     mirror/align/distribute/group/zorder/...     │
│ engine/history (快照栈 undo/redo)                 │
│ engine/layout (autoPlace/clamp/相对定位)          │
│ freehand/FreehandSceneStage (手绘动画渲染)         │
│   ├ perfect-freehand (变宽墨带)                   │
│   └ vpath 贝塞尔矢量插画                          │
│ voice/tts (豆包TTS + speechSynthesis 降级)        │
└──────────────┬───────────────────────────────────┘
               │ ws(ASR) + HTTP(LLM/TTS)
               ▼
┌─ Backend (Express + ws) ────────────────────────┐
│ asr/gateway: ws://host/asr 转发火山豆包流式 ASR    │
│   ├ volc-codec (二进制帧协议)                     │
│   ├ mock 上游 (固定话术演示)                       │
│   └ 密钥隔离 (前端不接触 VOLC_API_KEY)             │
│ llm/handler: POST /api/llm/parse                 │
│   ├ 方舟 doubao-seed-2.0-pro 流式 SSE             │
│   ├ 首 token 超时 (parse 8s/plan 20s)             │
│   ├ 总时长兜底 (parse 30s/plan 90s)               │
│   └ System Prompt 构建期生成 (命中 prompt cache)   │
│ tts/handler: GET/POST /api/tts                   │
│   └ 豆包 TTS 2.0 分块流式                          │
└──────────────┬───────────────────────────────────┘
               │
               ▼
   火山引擎豆包 ASR/LLM/TTS (三级降级兜底)
```

**关键调用链追踪（"画一个雪人"多主体）**：
1. `useVoice` VAD 断句 → ASR final "画一个雪人" → `onUtterance`
2. `orchestrate.orchestrateSubplans`（`orchestrate.ts:220`）判断多主体 → `planLayout` 布局 → `deoverlapBoxes` AABB 去重叠（`:185`）
3. `backgroundOps`（`:116`）按关键词选天/地配色，瞬时铺背景
4. 各角色并发 `parseWithLlm(prompt, 'plan', ctx)`（`:291`），按框面积给笔数预算（10-22）
5. 串行 chain 应用：`executeTransaction(bgScene, ops)` 隔离执行（`:303`，消除跨角色串台）→ `fitGroupToBox` 仿射贴框（`:57`）→ 重分配全局唯一 id（`{旧id}@{label}`）→ `cb.onScene` 渐进上屏
6. `engine/interpreter.executeTransaction` 纯函数执行 14+ Op，失败保留已成功 Op（协议 §1.5）
7. `FreehandSceneStage` 逐笔手绘动画渲染

**状态流**：VoiceState FSM（idle/listening/parsing/speaking）→ SceneState（objects/z/seq）→ history 快照栈
**错误流**：LLM 首 token 超时 → AbortController 中止 → 504 → 前端回退缓冲重试；AMBIGUOUS_TARGET → `clarify.buildAmbiguityClarify` 构造澄清问题 → 下一句匹配 expecting
**可观测**：调试面板文本输入验证全链路 + `onLog` 回调 + `/healthz` 探测降级状态

---

## 工程评分

| 维度 | 分数 | 证据 |
|------|------|------|
| 产品完成度 | 4.5 | 26 项能力 P0 11/11 + P1 8/8，完整语音闭环 + 多主体编排 + 流式渐现 |
| 架构边界 | 4.5 | dsl/engine/nlu/freehand/voice 五子系统职责清晰，纯函数解释器 + 快照栈 |
| 可维护性 | 4 | 模块化好，但 `interpreter.ts` 1239 行 + `App.tsx` 855 行偏大 |
| 可测试性 | 5 | 28 个测试文件，Golden 30 句规格测试，测试源码占比约 40%，含离线+真实 LLM 模式 |
| 可观测性 | 3.5 | 调试面板 + onLog + healthz 探测，但无结构化日志/监控 |
| 安全隐私 | 4 | 密钥隔离代理（前端不接触密钥）+ 三级降级 + 麦克风权限；CORS * 偏宽松但本地工具 |
| 性能并发 | 4 | 多主体并发 LLM + 串行应用避竞态 + VAD 静音帧不上传 + 思考模式关换取图速度 |
| 资源释放 | 4 | AbortController 超时 + VAD pause + idleTimer 2 分钟休眠 |
| 成本控制 | 4 | 规则快路径零 LLM 成本 + VAD 断句省 ASR + prompt cache 命中 |
| 部署恢复 | 4.5 | 一条命令 pnpm dev + 无密钥降级可跑 + pnpm workspace |
| 文档 | 5 | 四份设计文档（架构/协议/规格/能力）+ CLAUDE.md 17KB，规格含 Golden 测试集 |
| 上手难度 | 3.5 | 需理解 DSL/引擎/三层理解，但调试面板可文本输入验证全链路 |

**问题分级**：
- **阻断**：无
- **重要**：
  - `interpreter.ts` 1239 行单文件，14+ Op 集中，扩展新 Op 需谨慎
  - LLM `plan` 模式总超时 90s（`handler.ts:29`），长输出可能占用连接
  - CORS `Access-Control-Allow-Origin: *`（`index.ts:16`），虽本地工具但生产化需收紧
- **一般**：
  - `App.tsx` 855 行状态编排偏重，可拆分
  - 依赖火山引擎三服务（ASR/LLM/TTS），供应商锁定（有 mock/WebSpeech 降级但不等效）
  - 绘图表达力受 DSL 图元限制（vpath 扩展缓解）
- **建议**：
  - interpreter 按 Op 类型拆分模块
  - 增加结构化日志（可观测性）
  - 支持更多 LLM 供应商（当前方舟锁定）

---

## 优点

1. **自研统一绘图 DSL + 纯函数解释器**（`dsl/schema.ts` + `engine/interpreter.ts`）：所有理解层输出同一套 zod strict Op，解释器纯函数不修改入参，是快照式 undo/redo 的前提
2. **三层指令理解分层**（`nlu/`）：规则快路径 <1ms 零成本（撤销/清空/导出）→ LLM 结构化解析（绘图/编辑/空间/指代）→ Agent 多主体拆解，按复杂度路由
3. **完整三级降级链**：ASR（火山豆包→mock→WebSpeech）、LLM（方舟→规则层）、TTS（豆包→speechSynthesis），无密钥也能跑
4. **多主体 Agent 编排**（`orchestrate.ts:220`）：并发 LLM + 串行应用 + 隔离执行消除跨角色串台 + AABB 去重叠 + 按框面积给笔数预算
5. **流式逐笔渐进出图**（v1.4）：LLM 增量透传 + 前端边收边渐进绘制，体验优于一次成图
6. **事务式执行 + 快照栈 undo/redo**（`engine/history.ts`）：`executeTransaction` 失败保留已成功 Op，快照栈天然支持撤销重做
7. **歧义澄清 + 破坏性确认**（`clarify.ts` + `confirm.ts`）：AMBIGUOUS_TARGET 构造颜色/位置区分问题，clear 等破坏操作语音二次确认（5 秒超时取消）
8. **同音词纠错**（`correction.ts`）：词表 + 拼音编辑距离回退，"花一个园"→"画一个圆"
9. **密钥隔离代理**（`backend/`）：前端不接触 VOLC_API_KEY/ARK_API_KEY，后端统一转发
10. **测试密度极高**：28 个测试文件，Golden 30 句规格测试，含离线全量 + 真实 LLM 实跑模式
11. **System Prompt 构建期生成**（`prompt.generated.ts`）：运行期逐字节不变命中上游 prompt cache，降本提速
12. **半双工互斥**（`useVoice.ts:52`）：TTS 播报期间丢弃麦克风帧防自激
13. **个人独立完成**：全部模块一人实现，工程素养突出

---

## 缺点风险与改进优先级

| 优先级 | 问题 | 影响 | 改进建议 |
|--------|------|------|----------|
| P1 | interpreter.ts 1239 行单文件 | 扩展维护风险 | 按 Op 类型拆分模块 |
| P1 | LLM plan 总超时 90s | 长输出占用连接 | 按输出长度动态超时 |
| P2 | CORS * 宽松 | 生产化安全风险 | 收紧为 dev origin |
| P2 | 火山引擎三服务锁定 | 供应商风险 | 抽象 provider 接口支持多供应商 |
| P2 | App.tsx 855 行状态编排 | 维护性 | 拆分工作流 + 状态管理 |
| P3 | 绘图表达力受 DSL 限制 | 复杂图形受限 | vpath 已扩展，持续增强 |
| P3 | 无结构化日志 | 线上排查难 | 引入日志框架 |
| P3 | 无用户系统 | 多用户场景受限 | 按需增加 |

---

## 复用性矩阵

| 资产 | 复用性 | 说明 |
|------|--------|------|
| 绘图 DSL Schema + 纯函数解释器 | 可直接复用 | 通用结构化绘图执行引擎，zod strict + 事务式 + 14+ Op |
| 三层指令理解分层 | 可直接复用 | 规则快路径/LLM 解析/Agent 拆解的路由模式 |
| 快照栈 undo/redo | 可直接复用 | 纯函数解释器 + 历史快照的通用模式 |
| 多主体 Agent 编排 | 改造后复用 | 并发 LLM + 串行应用 + 隔离执行，可迁移到其他多主体生成 |
| 三级降级链 | 可直接复用 | mock/WebSpeech/speechSynthesis 降级思路通用 |
| VAD 断句 + ASR FSM | 改造后复用 | 本地 VAD + 流式 ASR + 半双工互斥，语音交互通用 |
| 歧义澄清 + 破坏性确认 | 可直接复用 | 语音交互的安全交互模式 |
| 同音词纠错 | 改造后复用 | 词表 + 拼音编辑距离，中文语音场景通用 |
| freehand 手绘渲染引擎 | 改造后复用 | perfect-freehand + vpath，可迁移到其他手绘应用 |
| 密钥隔离代理后端 | 可直接复用 | Express + ws 的 LLM/ASR/TTS 代理模式 |
| 具体火山豆包协议编解码 | 不应复用 | 供应商特定，需按目标供应商重写 |

**复用评分**：
- 技术复用：5（DSL/解释器/三层理解/降级链/Agent 编排全套可迁移，是语音交互+结构化执行的样板）
- 产品复用：3.5（语音绘图闭环可迁移到语音操控其他结构化任务）
- 商业复用：3（无障碍/儿童教育有空间，但绘图表达力与 LLM 成本是天花板）

---

## 值得学习的内容

1. **（进阶）自研 DSL + 纯函数解释器 + 快照栈**：把不可控的 LLM 输出约束到可校验的 DSL，纯函数执行天然支持事务式 undo/redo，是 LLM 驱动结构化操作的核心工程模式（`dsl/schema.ts` + `engine/interpreter.ts`）
2. **（进阶）三层指令理解分层路由**：规则快路径（零成本）→ LLM 解析（结构化）→ Agent 拆解（多主体），按复杂度路由平衡成本与能力（`nlu/`）
3. **（进阶）多主体 Agent 并发编排 + 隔离执行**：并发 LLM 降时延 + 串行应用避竞态 + 隔离执行消除跨角色串台，是 LLM 多主体生成的优雅解（`orchestrate.ts:220`）
4. **（可迁移）三级降级链设计**：每个外部依赖都有降级方案，无密钥也能跑，是 demo 作品可用性的保障
5. **（可迁移）流式逐笔渐进出图**：LLM 增量透传 + 前端边收边绘制，把"等几十秒"变成"看着它画"，体验质变（`handler.ts:165`）
6. **（可迁移）歧义澄清 + 破坏性确认**：语音交互中 AMBIGUOUS_TARGET 构造区分问题、破坏操作二次确认，是安全交互范式（`clarify.ts` + `confirm.ts`）
7. **（可迁移）System Prompt 构建期生成 + prompt cache**：运行期逐字节不变命中上游缓存，降本提速（`prompt.generated.ts`）
8. **（可复刻）Golden 测试集 + 离线/真实双模式**：30 句规格测试，离线全量 + 真实 LLM 实跑，是 LLM 应用回归测试的样板
9. **（可迁移）半双工互斥防自激**：TTS 播报期间丢弃麦克风帧，语音交互必备（`useVoice.ts:52`）
10. **（初阶）zod strict 防静默错误**：未知字段一律拒绝，LLM 输出拼错立刻失败触发重试，而非静默画出错误结果（`schema.ts:7`）

---

## 结构化 YAML 摘要

```yaml
project: voice-draw
one_line_judgment: "纯语音控制 AI 绘图工具，自研 DSL+纯函数解释器+三层理解+三级降级，技术原创度与测试密度最高"
product_type: "语音交互结构化绘图工具"
target_users: ["创作节参赛场景", "无障碍绘图用户", "儿童语音创作", "语音交互方案演示者"]
core_loop: "语音输入 → VAD断句+流式ASR → 三层理解(规则/LLM/Agent) → DSL校验 → 纯函数解释器 → freehand手绘渲染 → TTS播报闭环"
architecture_style: "前端五大子系统(dsl/engine/nlu/freehand/voice) + 后端密钥隔离代理，纯函数解释器+快照栈"
stack: ["React 18", "TypeScript", "Vite", "zod", "perfect-freehand", "vitest", "ws", "@ricky0123/vad-web", "pinyin-pro", "onnxruntime-web", "Express", "dotenv", "火山引擎豆包ASR", "火山方舟doubao-seed-2.0-pro", "豆包TTS2.0"]
strongest_patterns: ["自研统一绘图DSL + zod strict校验", "纯函数解释器 + 事务式执行 + 快照栈undo/redo", "三层指令理解分层路由(规则/LLM/Agent)", "多主体Agent并发编排+隔离执行+去重叠", "流式逐笔渐进出图", "三级降级链(火山/mock/WebSpeech)", "歧义澄清+破坏性二次确认", "同音词纠错(词表+拼音编辑距离)", "System Prompt构建期生成+prompt cache", "半双工互斥防自激", "密钥隔离代理", "Golden测试集+离线/真实双模式"]
main_risks: ["interpreter.ts 1239行单文件", "LLM plan总超时90s连接占用", "CORS *宽松", "火山引擎三服务供应商锁定", "App.tsx 855行状态编排", "绘图表达力受DSL限制"]
business_scenarios: ["无障碍语音绘图", "儿童语音创作", "语音交互方案演示", "LLM驱动结构化操作样板"]
reusable_assets: ["绘图DSL Schema+纯函数解释器", "三层指令理解分层", "快照栈undo/redo", "多主体Agent编排", "三级降级链", "VAD断句+ASR FSM", "歧义澄清+破坏性确认", "同音词纠错", "freehand手绘渲染引擎", "密钥隔离代理后端", "Golden测试集模式"]
non_reusable_parts: ["火山豆包协议编解码", "具体绘图Op实现", "方舟特定prompt"]
scores:
  product: 4.5
  architecture: 4.5
  engineering: 4.5
  reuse: 5
  commercialization: 3
evidence:
  - "frontend/src/dsl/schema.ts:1-100 (DSL zod strict Schema)"
  - "frontend/src/engine/interpreter.ts:1-80 (纯函数解释器+事务式执行)"
  - "frontend/src/engine/interpreter.ts:698-1170 (14+ Op 实现)"
  - "frontend/src/nlu/orchestrate.ts:220-377 (多主体Agent编排)"
  - "frontend/src/nlu/orchestrate.ts:185-218 (AABB去重叠)"
  - "frontend/src/nlu/llm.ts:1-120 (分层场景上下文SceneSummary)"
  - "frontend/src/nlu/clarify.ts:56 (歧义澄清)"
  - "backend/src/llm/handler.ts:112-216 (LLM流式代理+超时)"
  - "backend/src/index.ts:1-46 (后端启动+密钥隔离)"
  - "frontend/src/voice/useVoice.ts:39-110 (VAD+ASR FSM+半双工)"
  - "28个.test.ts测试文件 (Golden 30句规格测试)"
  - "docs/四份设计文档 (架构/协议/规格/能力)"
confidence: "高"
```
