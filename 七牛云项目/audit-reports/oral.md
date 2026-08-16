# oral 项目审查报告

> 审查方法论：qiniu-project-audit（6 步：项目边界 → 产品回路 → 技术架构 → 工程质量评分 → 优缺点与复用矩阵 → 学习内容）
> 审查日期：2026-08-15
> 证据纪律：引用文件路径 + 行号；结论标注 fact / inference / hypothesis；先读高密度文件；不把文档目标当已实现

---

## 1. 项目边界

| 项 | 值 |
|---|---|
| 仓库路径 | `/Users/allure/Desktop/七牛云项目/oral/` |
| 产品名 | AI 英语口语陪练（internal name: oral） |
| 技术栈 | Python 3.12 + FastAPI + google-genai（Gemini Live + Gemini judge）+ faster-whisper + React 19 + Vite 8 + recharts + SQLite |
| 后端 LOC | ~4986 行（app/ 下 .py，fact，`wc -l`） |
| 前端 LOC | ~5148 行（frontend/src 下 jsx/js，fact） |
| 测试 | 后端 273 个 test 函数 / 18 个测试文件；前端有 vitest（live/polling/nudge/api/sessions/modes/questions/report/audio 等多组测试）（fact） |
| Git 历史 | 仅 1 个 commit（`9d303f6 update readme`）（fact，`git log --oneline`） |
| 用户模型 | 单写死 demo 用户，无账号 / 多用户（fact，`app/db.py` 模块 docstring + `app/schema.sql` 注释 "单写死 demo 用户：不设 users 表"） |
| 已知 bug | 本地直连 Gemini 受限，必须配置代理（fact，README 已声明 + `app/live/client.py` docstring） |

**边界判定**：这是一个面向单用户的英语口语练习 demo，核心是「实时对话 + 课后结构化报告」的完整闭环，不是生产级多租户 SaaS。IELTS 考试模拟的还原度是该项目的差异化重点。

---

## 2. 用户与产品回路

### 目标用户（inference）
- 备考 IELTS Speaking 的考生（需要全真模拟 + 官方 band 评分对标）
- 想练日常场景口语的英语学习者（点餐 / 开会等，需要中文求助兜底）

### 核心产品回路
```
选模式 → 实时对话/录音 → 结束会话 → ≤5s 结构化报告 → Library/Review 复盘（进步曲线）
```

三种模式（fact，README + `app/schema.sql` 的 mode/sub_mode 枚举）：

1. **IELTS 方式 A（live 模拟考）**：整场考试，考官（Gemini Live 扮演）驱动 P1→P2 备题→P2 长谈→P3→结束的状态机推进；产出四维 band + overall_band + 诊断层。
2. **IELTS 方式 B（分模块练习）**：按 Part 单独录音练习；四维仅作内部诊断依据，**最终报告不出数字 band**（单 Part 样本碎，band 解释力弱），只给 descriptor 对齐诊断。
3. **情景对话**：AI 扮演场景角色（点餐/开会），用户可夹中文求助（language_help tool），模型可即时纠错（grammar_note tool）；不出 band，产出诊断层 + 会话内 FC 反馈实录 + summary。

**报告产出契约**（fact，`app/report.py` + `app/judge/run.py:193-249`）：
- 雅思方式 A：四维 band（0.5 半档对齐）+ overall_band（系统聚合）+ 诊断层；judge 拒评标 unscorable 而非抛错。
- 雅思方式 B：dimensions/overall_band 强制置 None，只保留诊断层；诊断全空才标 unscorable。
- 情景：强制无 band，rewrites 强制清空（会话内已即时纠正），summary 仅情景保留。

---

## 3. 技术架构

### 3.1 增量评测流水线（核心架构亮点）

设计目标：会话结束到报告就绪 ≤5s（fact，README）。

实现（fact，`app/pipeline.py` + `app/live/tee.py` + `app/judge/run.py`）：

```
会话中（增量）：
  用户音频帧 → UserAudioTee 按轮次边界切片
            → 每片后台 ingest_clip：faster-whisper 转写 + Gemini Files API 预上传
            → 结果挂 turns 行（transcript_json + file_uri）

会话结束（finalize）：
  merge_transcripts（跨片时间戳偏移合并）
  → compute_signals（确定性，无 LLM）
  → run_judge（一次 Gemini 调用，temperature=0 + response_schema）
  → 系统确定性回填（practice_summary / overall_band / unscorable / vocabulary_diversity_pct）
  → 落库 reports 行
```

关键：把 whisper 转写 + 文件预上传**前移到会话内**，课后只剩一次 judge 调用，这是 ≤5s 的来源（fact，`app/pipeline.py:27-58`）。

### 3.2 确定性优先的 judge 设计

`app/judge/run.py:193-249` 体现「LLM 只产它该产的，其余系统确定性回填」：
- LLM 只产出 `dimensions`（雅思四维）+ `diagnostics`（诊断层）——`JudgeReport` schema 限定（`app/report.py:128-137`）。
- `practice_summary`：用 signals 的事实值，不让 LLM 猜（`run.py:196-200`）。
- `overall_band`：系统按四维平均 + round_to_half 聚合，judge 不自算（`app/judge/aggregate.py` + `run.py:220`）。
- `vocabulary_diversity_pct`：就是 TTR×100，后端从 signals 回填（`run.py:204-206`）。
- `unscorable` / `unscorable_reason`：系统按 dimensions 是否为 None 设置（`run.py:211-216`）。
- 方式 B 的 dimensions/overall_band 强制置 None，情景 rewrites 强制清空、summary 剥除——**不靠 LLM 自觉**（`run.py:221-248`）。

grounding 铁律写进 prompt（fact，`app/judge/prompt.py:21-27`）：证据必须逐字引用考生原话、不得编造、客观信号是输入非成绩、保持确定性与保守。

### 3.3 IELTS 方式 A 导演状态机

`app/live/director.py`（639 行）是项目最复杂的组件。

**状态机**（fact，`director.py`）：`p1 → p2_prep → p2_talk → p3 → done`，`_STATE_ORDER` 单调推进。

**核心设计——考官（模型）驱动转场**（fact，`director.py` EXAMINER_SYSTEM_INSTRUCTION + 转场短语）：
- 考官说出宣告短语（如 _P1_END_PHRASES）声明进入下一阶段。
- 后端 `on_examiner_transcript` 用子串匹配检测到宣告 → 种下 `_pending`（defer）。
- **转场延迟到 `turn_complete`** 才兑现——保证「语音先于视觉」（考官说完话 UI 才动），末问不被吞。

**安全网**（fact，`director.py` 常量）：`MAX_P1_S=300`、`MAX_P2_TALK_S=210`、`MAX_P3_S=300`、`MAX_MONOLOGUE_S=130`、`OPENING_NUDGE_S=10`（开场看门狗，3 次尝试）。超时强制转场。

**防自取消铁律**（fact，`director.py` 注释 review W1）：计时器回调检查当前状态是否符合预期，避免看门狗/备题计时器在状态已推进后误触发回退。

### 3.4 WS ⇄ Gemini Live 桥接

`app/live/bridge.py`（255 行）：`bridge()` 并发跑上行/下行泵。
- `_pump_upstream`：转发音频帧（tee/meter 钩子），处理控制消息（end_session/turn_end/ready/nudge），director.input_paused 在备题期丢帧。
- `_pump_downstream`：转发音频字节、transcript_delta、interrupted（barge-in）、turn_complete、tool_call。
- 钩子在 `await` 之前调用（边界状态在事件之前）。

### 3.5 UserAudioTee 楼层状态机

`app/live/tee.py`（160 行）：按轮次边界切分用户音频喂增量流水线。
- `BYTES_PER_SECOND=32000`（16kHz/16bit/mono），`MIN_CLIP_SECONDS=0.4`，`PREBUFFER_SECONDS=2.0`（barge-in 回补）。
- 楼层状态机：用户初始持楼层 → 模型音频到则楼层转移、切上一片 → turn_complete 则楼层归还 → interrupted 则楼层归还带 prebuffer。
- `finish()` 幂等，之后所有钩子失效；`drain()` 等全部 ingest 任务；`_ingest` 用 `asyncio.Lock`（whisper 单例不并发）；单片失败不崩会话。

### 3.6 情景对话教练协议

`app/live/help.py`（258 行）：
- **LanguageHelpDesk**：处理 language_help（求助应答）+ grammar_note（纠错控频）。纯本地零外呼（翻译由 Live 模型自己带语境做，tool 不再外呼）。
  - 模板轮换（防生硬重复）+ 连续求助控频（`HELP_OVERUSE_THRESHOLD=3` 起改「鼓励先自己试」）。
  - grammar_note 三态：speak（最前一句纠正）/ silent（同轮双发压掉 / mixed_cn 同轮 recast 已覆盖）/ after_help（中文应答之后）。
  - 反馈实录与 WS 事件同源同序留存，课后导出进报告。
- **ScenarioNudger**：前端沉默计时器分级发 nudge，后端查表注入舞台指令 + 防抖（`NUDGE_DEBOUNCE_S=8`）。

### 3.7 数据层

`app/db.py` + `app/schema.sql` + `app/crud.py`：
- SQLite，schema.sql 是结构源真理，代码不硬编码 DDL。
- `init_db()` 全 `IF NOT EXISTS` 可安全重复执行；`_ensure_columns` 幂等补列，SQL 标识符白名单掐死注入面（`db.py` `_IDENT_RE` / `_DDL_RE`）。
- 一次性数据迁移用 `PRAGMA user_version` 分步门控，**绝不每次启动重跑**（review C1，`db.py` `_migrate_status_enum_once`）。
- `get_connection()` 上下文管理器：开外键、按列名取行、成功提交/异常回滚/总是关闭。

### 3.8 前端

React 19 + Vite 8 + recharts + tailwindcss 4。路由：Home / IeltsSelect / ScenarioSelect / Live / Record / Report / Library / Review。
- `lib/live.js`：WS 客户端（契约 SCHEMA §6.1），有 vitest 测试 pin 事件 shape。
- `lib/audio/`：recorder / player / wavEncoder / pcmWorkletProcessor，有测试。
- `lib/polling.js` / `lib/nudge.js`：报告轮询 / 沉默分级探询。
- 16k PCM 上行 / 24k PCM 下行，零转码（fact，`app/live/client.py` 常量 + README）。

---

## 4. 工程质量评分（11 维，1-5）

| 维度 | 分 | 依据 |
|---|---|---|
| 架构合理性 | 5 | 增量流水线把耗时操作前移到会话内、确定性优先的 judge、director 状态机、tee 楼层状态机——每个核心问题都有专门的、经过推敲的结构应对（fact，pipeline/director/tee/judge） |
| 代码质量 | 4 | 类型标注完整（Python type hints + Pydantic）、命名清晰、防御性编码到位（deep copy 防原地改、finally 取消计时器、orphan 清理、强引用防 GC）；但注释密度极高近乎过度文档化，存在注释-代码漂移风险（inference） |
| 测试覆盖 | 4 | 后端 273 个 test 函数 / 18 文件，覆盖 director/pipeline/signals/judge/tee/help/ws 全核心；前端有 vitest 多组。但无集成/E2E、无覆盖率阈值（fact） |
| 可维护性 | 3 | 单 commit 历史无法追溯演进；注释虽详尽但部分像开发日记（"review W1"/"反馈①"/"联调发现②"）指向外部文档，脱离上下文难懂；prompt 文本散落多处（inference） |
| 可扩展性 | 4 | 情景 case 注册表设计「加 case = 只写文本不碰代码」（fact，`scenario_cases.py` docstring）；mode/sub_mode 枚举可扩展；但 judge/director 与 Gemini Live + IELTS 域强耦合（inference） |
| 性能优化 | 5 | 增量流水线达成 ≤5s 报告目标；whisper 单例 + asyncio.Lock 防并发；select_pronunciation_clips 只挑最长 3 片省 token；PCM 零转码（fact） |
| 安全性 | 3 | SQLite 标识符白名单防注入；GEMINI_API_KEY 走后端环境变量；但单 demo 用户无鉴权、无输入消毒（WS 消息按 JSON 解析）、proxy env 全局接管有副作用风险（fact + inference） |
| 错误处理 | 4 | judge 5xx 退避重试、Files API 失败降级 inline、单片 ingest 失败不崩会话、unscorable 软失败保留诊断层、orphan 清理、tool 幻觉调用不抛错（fact，run.py/help.py/live_ws.py） |
| 文档质量 | 4 | README 清晰、schema.sql 注释到位、模块 docstring 详尽；grounding/language rules 写进 prompt 可追溯；但无架构图、无 API 契约文档（前端 lib/live.test.js pin 了部分契约）（fact + inference） |
| 部署运维 | 2 | 无 Dockerfile、无 CI、无部署文档；`app_reload` 默认 True 但 live WS 必须设 `APP_RELOAD=0`（fact，config.py）；单 demo 用户无生产部署路径 |
| 依赖管理 | 3 | pyproject.toml 列依赖但无 lock 文件；google-genai 用 preview 模型（`gemini-3.1-flash-live-preview`）有版本漂移风险；前端 package.json 有版本号（fact） |

**综合工程分：4**（核心架构与测试极强，部署/运维/安全是短板，符合 demo 定位）

---

## 5. 优缺点与复用矩阵

### 优点
1. **增量评测流水线**：whisper + Files API 预上传前移到会话内，课后一次 judge 调用——这是 ≤5s 报告的工程根因，可直接复用到任何「实时会话 + 课后报告」场景（fact）。
2. **确定性优先的 LLM 调用范式**：temperature=0 + response_schema + 系统回填关键字段 + grounding 铁律写进 prompt——最大限度压住 LLM 漂移，是「LLM as part, 确定性引擎守全局状态」的范本实现（fact）。
3. **导演状态机的「考官驱动转场 + defer 到 turn_complete」**：让 AI 自然推进考试流程，后端只做检测与安全网，用户体验远好于按钮驱动（fact）。
4. **UserAudioTee 楼层状态机**：按对话轮次边界切音频，处理 barge-in 回补、幂等收尾、单片失败隔离——实时音频切片的通用模式（fact）。
5. **情景 case 注册表**：加场景只写文本（persona + judge_focus + openers），全链生效，扩展成本极低（fact）。
6. **测试密度高且确定性**：signals/director/pipeline 测试用合成数据 + mock，零网络零模型，可确定性复算（fact，测试文件头部注释）。

### 缺点 / 风险
1. **单 commit 历史**：开发过程不可追溯，所有「review W1 / 联调发现②」类注释指向的决策上下文丢失（fact）。
2. **单 demo 用户无鉴权**：无账号 / 多租户路径，商业化需从零搭用户体系（fact）。
3. **Gemini 强耦合 + preview 模型**：judge 与 Live 都绑 Gemini，live_model 是 preview 版本，换模型 / 模型下线影响大；无 provider 抽象层（inference，对比 EnglishPartner 的 Provider 可替换架构）。
4. **代理必配的已知 bug**：本地直连受限，`client.py` 全局接管 proxy env 有副作用（fact）。
5. **注释过度文档化**：部分注释像开发日记引用外部编号（"反馈①"/"done/007"），脱离原始上下文后可读性下降，维护负担高（inference）。
6. **无 CI / 无部署配置**：无 Dockerfile、无 lock 文件、`app_reload` 默认与 live WS 冲突需手动关（fact）。
7. **prompt 文本膨胀**：`director.py` 的 EXAMINER_SYSTEM_INSTRUCTION 70+ 行、`scenario_cases.py` 的 _SHARED_RULES 很长——单文件 prompt 膨胀是后续维护风险（fact）。

### 复用矩阵

| 资产 | 复用价值 | 复用条件 | 不可复用部分 |
|---|---|---|---|
| `app/signals.py` 客观信号计算 | 高 | 任何口语评测；依赖 wordfreq + 词级时间戳 | 无 |
| 增量流水线编排（`pipeline.py`） | 高 | 任何「会话 + 课后报告」；需配 whisper + Files API 等价物 | ingest 细节绑 Gemini Files API |
| 确定性 judge 范式（`judge/run.py` + `prompt.py` grounding rules） | 高 | 任何 LLM 结构化评分；换模型换 schema | response_schema 绑 Gemini / IELTS 诊断 schema |
| 导演状态机（`director.py`） | 中 | IELTS / 多阶段考试模拟；需重写转场短语与状态 | 强绑 IELTS 流程 + Gemini Live |
| UserAudioTee 楼层状态机（`tee.py`） | 高 | 任何实时双工音频会话切片 | PCM 参数可配 |
| LanguageHelpDesk 模板控频 + grammar 三态（`help.py`） | 中 | 情景对话教练协议；需配 tool 声明 | 绑 Live tool calling 协议 |
| schema.sql + PRAGMA user_version 迁移 | 中 | SQLite demo 项目 | 单用户无鉴权设计 |
| 前端 lib/live.js WS 客户端契约 | 中 | 任何 WS 实时对话前端 | 事件 shape 绑本产品 |
| 情景 case 注册表模式（`scenario_cases.py`） | 高 | 任何「加内容只写文本」的扩展场景 | persona 文本本身 |

---

## 6. 学习内容

### 6.1 可直接学习的工程模式
1. **增量流水线前移耗时操作**：把转写 / 上传放到会话内后台跑，课后只剩一次 LLM 调用——这是「实时会话 + 课后报告」低延迟的标准答案。
2. **LLM 结构化输出的确定性收口**：response_schema 限定 LLM 产出域 + 系统回填所有可确定性字段 + grounding 铁律写进 prompt——三重防线压漂移。
3. **AI 驱动 + 后端检测的状态机**：让模型自然推进流程（说宣告短语），后端只做子串检测 + defer 到自然边界 + 超时安全网——比按钮驱动更像真实考试。
4. **音频楼层状态机**：用「谁在说话」的楼层概念切分双工音频，处理 barge-in 回补与幂等收尾。
5. **SQLite 无迁移体系的幂等补列 + PRAGMA user_version 一次性迁移**：demo 级数据演进的轻量方案，标识符白名单防注入。
6. **「加内容只写文本」的注册表模式**：scenario_cases 把 persona/judge_focus/openers 数据化，全链自动生效。

### 6.2 可反思的教训
1. **单 commit 历史让所有开发决策不可追溯**：审查时无法验证「review W1」类注释指向的修复是否真发生过——Git 历史是审查证据的基础设施。
2. **注释过度文档化的代价**：引用外部编号的注释在脱离原始上下文后变成噪声，代码自文档化 + 独立 ADR 文档更可持续。
3. **provider 强耦合的商业化风险**：对比 EnglishPartner 的 Provider 可替换架构，oral 把 judge + Live 都硬绑 Gemini，模型下线 / 换模型成本高。
4. **demo 与生产的边界要早划**：单 demo 用户、无鉴权、`app_reload` 默认冲突——这些在 demo 阶段合理，但若无明确迁移计划会变成技术债。

### 6.3 与同批项目的横向对比
- **与 PlotPulse 共享**：「LLM as part, 确定性引擎守全局状态」范式——oral 的 overall_band 系统聚合、signals 确定性计算与 PlotPulse 的 cut-impact 纯函数分析同源。
- **与 EnglishPartner 对比**：EnglishPartner 用 Provider 可替换 + fallback 换来健壮性；oral 用确定性优先 + grounding 铁律换来评分一致性——两种应对 LLM 不确定性的思路，oral 更深但更窄（强绑 Gemini）。
- **共同风险**：prompt 在单文件膨胀（oral 的 director persona + scenario _SHARED_RULES）、git 历史压缩导致开发过程不可验证——是这批项目的通病。

---

## 审查结论

oral 是一个**架构设计极其用心、工程实现质量很高**的单用户 demo。它的核心价值不在产品完成度（单用户、无部署），而在**「实时会话 + 课后结构化报告 ≤5s」的工程范式**与**「AI 驱动考试流程 + 确定性优先评分」的设计范式**。增量流水线、确定性 judge 收口、导演状态机、音频楼层状态机都是可复用到其他实时 AI 会话项目的高价值资产。主要短板在 provider 耦合、单用户无鉴权、无 CI/部署——这些是 demo 定位的合理取舍，但若要商业化需系统性补齐。

---

```yaml
project: oral
one_line_judgment: 架构用心的单用户英语口语 demo，核心价值是「实时会话+课后≤5s结构化报告」的增量流水线范式与「AI驱动考试+确定性优先评分」的设计范式
product_type: AI 英语口语陪练（IELTS 模拟 + 情景对话）
target_users: IELTS 备考考生 + 日常场景口语练习者
core_loop: 选模式 → 实时对话/录音 → 结束 → ≤5s 结构化报告 → Library/Review 复盘进步曲线
architecture_style: 增量评测流水线（会话内转写+预上传，课后一次 judge）+ 确定性优先 LLM 调用（response_schema+系统回填+grounding 铁律）+ 导演状态机（考官驱动转场+defer+安全网）+ 音频楼层状态机
stack: [Python 3.12, FastAPI, google-genai, Gemini Live, Gemini judge, faster-whisper, React 19, Vite 8, recharts, tailwindcss 4, SQLite, wordfreq]
strongest_patterns:
  - 增量流水线前移耗时操作（whisper+Files API 会话内跑，课后一次 judge）
  - 确定性优先 judge（temperature=0+response_schema+系统回填 overall_band/vocabulary_diversity_pct/unscorable）
  - 考官驱动转场状态机（宣告短语检测+defer 到 turn_complete+超时安全网+防自取消）
  - UserAudioTee 楼层状态机（按轮次边界切音频+barge-in 回补+幂等收尾）
  - 情景 case 注册表（加场景只写文本不碰代码）
  - grounding 铁律写进 prompt（逐字引用+禁编造+信号是输入非成绩）
main_risks:
  - 单 commit 历史开发过程不可追溯
  - 单 demo 用户无鉴权无多租户
  - Gemini 强耦合（judge+Live）+ preview 模型版本漂移
  - 代理必配的已知 bug + 全局接管 env 副作用
  - 注释过度文档化引用外部编号难维护
  - 无 CI/无部署配置/app_reload 默认冲突
  - prompt 单文件膨胀风险
business_scenarios:
  - IELTS Speaking 全真模拟考（方式 A）
  - IELTS 分模块针对性练习（方式 B）
  - 日常情景对话练习（点餐/开会，带中文求助兜底）
reusable_assets:
  - app/signals.py（客观信号确定性计算，依赖 wordfreq+词级时间戳）
  - app/pipeline.py（增量流水线编排范式）
  - app/judge/run.py + prompt.py grounding rules（确定性 judge 范式）
  - app/live/tee.py（音频楼层状态机）
  - app/scenario_cases.py 注册表模式
  - app/db.py PRAGMA user_version 迁移 + 标识符白名单
  - frontend/src/lib/live.js（WS 客户端契约）
non_reusable_parts:
  - director.py 转场短语+状态机（强绑 IELTS 流程）
  - EXAMINER_SYSTEM_INSTRUCTION persona 文本
  - scenario_cases persona/_SHARED_RULES 文本
  - 单 demo 用户无鉴权设计
  - Gemini Files API 预上传细节
scores:
  product: 5
  architecture: 5
  engineering: 4
  reuse: 4
  commercialization: 2
evidence:
  - path: app/pipeline.py
    lines: 27-58
    note: 增量流水线 ingest_clip（会话内转写+预上传）+ finalize_session（课后一次 judge）
    type: fact
  - path: app/judge/run.py
    lines: 193-249
    note: 系统确定性回填 practice_summary/overall_band/unscorable/vocabulary_diversity_pct，LLM 只产 dimensions+diagnostics
    type: fact
  - path: app/judge/aggregate.py
    lines: 全文
    note: overall_band 四维平均+round_to_half，judge 不自算
    type: fact
  - path: app/judge/prompt.py
    lines: 21-27
    note: grounding 铁律（逐字引用/禁编造/信号是输入非成绩/确定性保守）
    type: fact
  - path: app/live/director.py
    lines: 268+
    note: IeltsDirector 状态机，考官驱动转场+defer 到 turn_complete+超时安全网+防自取消
    type: fact
  - path: app/live/tee.py
    lines: 全文
    note: UserAudioTee 楼层状态机，按轮次边界切音频+barge-in 回补+幂等收尾
    type: fact
  - path: app/live/bridge.py
    lines: 82-255
    note: WS⇄Gemini Live 双向泵，钩子在 await 前调用
    type: fact
  - path: app/live/help.py
    lines: 51-219
    note: LanguageHelpDesk 模板轮换+控频+grammar 三态+反馈实录
    type: fact
  - path: app/live/client.py
    lines: 全文
    note: Gemini Live 连接工厂，proxy env 全局接管（WS 与 judge 代理机制不同），建链重试一次
    type: fact
  - path: app/report.py
    lines: 128-151
    note: JudgeReport schema 限定 LLM 产出域，Report 含系统字段
    type: fact
  - path: app/db.py
    lines: _migrate_status_enum_once + _ensure_columns
    note: PRAGMA user_version 一次性迁移+标识符白名单防注入
    type: fact
  - path: app/schema.sql
    lines: 全文
    note: sessions/turns/reports 表，status 枚举，单 demo 用户
    type: fact
  - path: app/scenario_cases.py
    lines: 模块 docstring
    note: 「加 case=只写文本不碰代码」注册表设计
    type: fact
  - path: app/config.py
    lines: 全文
    note: app_reload 默认 True，live WS 需手动 APP_RELOAD=0
    type: fact
  - path: tests/
    note: 273 个 test 函数/18 文件，signals/director/pipeline 用合成数据+mock 确定性测试
    type: fact
  - path: git log
    note: 仅 1 commit（9d303f6 update readme），开发过程不可追溯
    type: fact
  - path: README.md
    note: 本地直连 Gemini 受限需配代理的已知 bug 声明
    type: fact
  - note: provider 强耦合 Gemini（judge+Live）无抽象层，对比 EnglishPartner 的 Provider 可替换架构
    type: inference
  - note: 注释过度文档化引用外部编号（review W1/反馈①/done/007）脱离上下文难维护
    type: inference
confidence: high
```
