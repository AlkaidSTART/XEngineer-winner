# 项目审查报告 — hunjing-screenplay（浑晶 · 剧创态）

> 审查日期: 2026-08-15
> 审查方法: qiniu-project-audit skill
> 代码库根: `/Users/allure/Desktop/七牛云项目/hunjing-screenplay/`

---

## 一、一句话定性

一个以"多 Agent LLM 流水线 + 程序级启发式评分"为骨架的小说转剧本工具，领域建模扎实、工程纪律强、测试覆盖优秀，是 5 个项目中工程成熟度最高的一个，但同步编排架构和单文件 SQLite 限制了长篇/并发场景的可扩展性。

---

## 二、项目地图

```
hunjing-screenplay/
├── backend/
│   ├── app/
│   │   ├── main.py                    # FastAPI 入口,9 routers,CORS,健康检查
│   │   ├── config.py                  # Settings dataclass,fail-soft API key 模式
│   │   ├── cli.py                     # 命令行工具
│   │   ├── parsers/                   # txt/epub/docx 三格式解析器 + dispatcher
│   │   ├── routers/                   # 9 个 API 路由模块
│   │   │   ├── novels.py              # 上传/列表/删除/章节
│   │   │   ├── story_bibles.py        # 故事圣经 CRUD + 自动抽取
│   │   │   ├── scenes.py              # 场景切分
│   │   │   ├── elements.py            # 元素抽取
│   │   │   ├── attributions.py        # 对白归属
│   │   │   ├── decisions.py           # 改编决策
│   │   │   ├── compose.py             # 端到端编排 + 结构报告
│   │   │   ├── optimize.py            # 人机协作优化 + 版本树
│   │   │   └── export.py              # Fountain/TXT/YAML 三格式导出
│   │   ├── services/
│   │   │   ├── compose_service.py     # 核心编排器(599 行)
│   │   │   ├── llm_client.py          # LLM 客户端,指数退避 + JSON fence 剥离
│   │   │   ├── ingest_service.py      # 小说摄入 + SQLite 持久化
│   │   │   ├── screenplay_store.py    # 剧本版本树持久化
│   │   │   ├── story_bible_service.py # 故事圣经 JSON 导入 + LLM 抽取
│   │   │   ├── screenplay_exporter.py # Fountain/TXT/YAML 导出器
│   │   │   ├── yaml_validator.py      # JSON Schema + 引用完整性双层校验
│   │   │   └── pipeline/
│   │   │       ├── scene_splitter.py      # Agent 1: 章节切场景
│   │   │       ├── element_extractor.py   # Agent 2: 场景抽剧本元素
│   │   │       ├── dialogue_attributor.py # Agent 3: 对白归属精修
│   │   │       ├── adaptation_decision.py # Agent 4: 内心独白改编 5 备选
│   │   │       ├── screenplay_optimizer.py# Agent 5: 人机协作优化引擎
│   │   │       ├── fidelity_scorer.py     # 程序级 4 维保真度评分
│   │   │       ├── structure_analyzer.py  # 程序级张力曲线 + 三幕分析
│   │   │       └── yaml_composer.py       # 纯函数 YAML 组装器
│   │   ├── prompts/                   # 5 个 .md prompt 文件(与代码分离)
│   │   ├── schemas/screenplay.json    # JSON Schema Draft 2020-12
│   │   └── db/                        # schema.sql × 3 + 连接管理 + 迁移
│   ├── tests/                         # 18 个测试文件,234 个测试函数,5681 行
│   └── requirements.txt               # 锁定版本(pinned)
├── frontend/
│   ├── src/
│   │   ├── stores/screenplay.ts       # Pinia store(443 行)
│   │   ├── api/client.ts              # 极简 fetch 封装
│   │   ├── types/screenplay.ts        # TS 类型对齐后端 schema
│   │   ├── router/index.ts
│   │   └── views/ + components/       # 9 个组件 + 2 个视图
│   └── package.json                   # Vue 3.5 + Pinia 3 + Vite 5(锁定版本)
├── docs/                              # SCHEMA_DESIGN / INTEGRATION_NOTES / 剧本术语速查
├── Makefile                           # 跨平台 make targets
└── README.md                          # 340 行,完整产品文档
```

---

## 三、产品与业务场景

**产品类型**: 小说自动转剧本的结构化创作辅助工具（AI Pipeline + 人机协作优化）

**目标用户**: 编剧/小说作者/影视专业学生——需要将小说文本改编为行业标准剧本格式的创作者。

**核心业务闭环**:
1. 上传小说（txt/epub/docx）→ 自动分章分段落
2. 生成故事圣经（角色/地点/关系/事件）—— LLM 自动抽取或手动 JSON 导入
3. 多 Agent 流水线编排：章节切场景 → 场景抽元素 → 对白归属精修 → 内心独白改编决策 → 保真度评分
4. 组装为结构化 YAML 剧本（通过 JSON Schema + 引用完整性双层校验）
5. 人机协作优化：单场精修 / 整本重排（LLM 引擎 + 诊断输入 + change_log 审计）
6. 版本树管理：每次优化存为新版本，parent 指向上一版
7. 三格式导出：Fountain（行业标准）/ TXT（中文友好）/ YAML（结构化数据）

**差异化卖点**（事实，基于 `prompts/adaptation_decision.md` 和 `pipeline/adaptation_decision.py`）:
- 不替作者决定内心独白如何改编，给出 5 种专业改编手法（V.O./动作外化/潜台词/意象化/删除）+ 利弊，作者拍板
- V.O. vs O.S. 术语区分（画外音 vs 画外音效）
- 保真度 4 维程序级评分（对白覆盖度/角色对齐/元素密度/决策完整度）
- 剧本结构分析（张力曲线 + 三幕分区 + 关键节点定位）

**场景定位**（合理推断）: 七牛云 1024 暑期实训营竞赛项目，README 明确标注"题目三"，以 demo 演示和评委复现为核心目标，非生产级 SaaS。

---

## 四、架构拆解

### 4.1 整体架构风格

**分层管道式架构（Pipeline + Service Layer）**，后端为 FastAPI 单体应用，无消息队列，编排走同步阻塞。

架构分层（事实）:
- **API 层** (`routers/`): 9 个路由模块，Pydantic 模型校验输入输出
- **编排层** (`compose_service.py`): 端到端 pipeline 编排 + 降级策略
- **Agent 层** (`pipeline/`): 5 个 LLM Agent + 2 个程序级评分器 + 1 个纯函数组装器
- **服务层** (`services/`): 摄入/存储/导出/校验/LLM 客户端
- **数据层** (`db/`): SQLite 单文件 + 3 个 schema 文件 + 幂等迁移
- **基础设施**: 配置从 .env 加载，prompt 与代码分离

### 4.2 多 Agent 流水线（最强设计点）

核心编排逻辑在 `compose_service.py:117` `orchestrate_full_pipeline()`，数据流为（事实）:

```
novel → bible(取或生成)
  → for chapter:
      scene_splitter(retry 2 次,阻断式)
      → for scene:
          element_extractor(retry 2 次,阻断式)
          → dialogue_attributor(失败降级,非阻断)
          → adaptation_decision(失败降级,非阻断)
          → fidelity_scorer(程序级,不调 LLM)
  → yaml_composer(纯函数组装 + ID 编号)
  → yaml_validator(JSON Schema + 引用完整性双层校验)
  → screenplay_store(持久化)
```

**降级策略**（事实，`compose_service.py:22-29`）:
- 非阻断：dialogue_attributor / propose_decisions / element_extractor 失败 → warning + 继续
- 阻断式：scene_splitter 整章失败 → 进 failed_chapters；bible 失败 → 整 pipeline raise

**每层 LLM 输出都有严格校验**（事实）:
- `scene_splitter.py:152` `_parse_and_validate_scenes()`: 枚举校验（INT/EXT、日/夜等）+ 范围越界截断 + 字段兜底
- `element_extractor.py:182` `_parse_and_validate_elements()`: 类型枚举 + 长度截断 + aka 映射 + 编造角色过滤
- `adaptation_decision.py:191` `_parse_decisions()`: options 完整性校验（5 种或 legacy 3 种）+ element_index 有效性
- `dialogue_attributor.py:201` `_parse_attributions()`: index 越界 + 类型防御 + 编造角色过滤

### 4.3 LLM 客户端

`llm_client.py` 设计（事实）:
- `call_chat()`: 指数退避重试 `time.sleep(2 ** attempt)`（第 104 行），默认 2 次重试
- `call_json()`: 在 call_chat 基础上剥离 markdown fence（`_strip_json_fence` 正则），解析失败时增强 prompt 提示"只输出 JSON"再重试
- 惰性初始化 OpenAI client（`_get_client()`），避免测试 import 时崩溃
- 区分 `LlmCallFailed`（网络层）和 `LlmJsonParseFailed`（解析层）两种异常

### 4.4 YAML Schema 校验

`yaml_validator.py` 双层校验（事实）:
- **Layer A**: JSON Schema Draft 2020-12（`schemas/screenplay.json`，355 行），含正则 ID 校验（`^char_\d{3,5}$` 等）、枚举校验、oneOf 元素类型
- **Layer B**: 引用完整性自检（`_validate_references()`），检查 character_id/location_id/scene_id/element_id 跨节点引用有效性 + 唯一性
- 错误消息中文化（`_humanize_schema_error()`）

### 4.5 程序级评分器（不调 LLM）

两个评分器设计哲学一致：可复现、免费、可单测（事实）:

**fidelity_scorer.py** — 4 维保真度（`fidelity_scorer.py:93-98` 权重）:
- dialogue_coverage 0.30 / character_alignment 0.30 / element_density 0.20 / decision_completeness 0.20
- 阈值：>=0.80 high / >=0.55 medium / 否则 low

**structure_analyzer.py** — 张力曲线 + 三幕分区（`structure_analyzer.py:184-241`）:
- 张力 5 信号加权：density 0.40 / conflict 0.20 / monologue 0.15 / casting 0.15 / fidelity 0.10
- 三幕固定比例 25/50/25 + 拐点修正
- 关键节点定位：inciting incident / midpoint / climax

### 4.6 版本树设计

`screenplay_store.py:36` `save_screenplay()` 支持 `parent_screenplay_id`（事实），`optimize.py:195` 优化后存为新版本并指向父节点。前端 `stores/screenplay.ts:342` `_attachChildOptimizationIfAny()` 可回溯子版本优化记录。

### 4.7 前端架构

Vue 3.5 + TypeScript + Pinia + Vite（事实，`package.json`）:
- 极简 fetch 封装（`api/client.ts`），无 axios 依赖
- Pinia store 集中管理剧本状态（`stores/screenplay.ts`，443 行）
- TS 类型严格对齐后端 schema（`types/screenplay.ts`）
- 组件化：9 个组件 + 2 个视图
- 版本锁定（`vue: ^3.5.13`，非 `latest`）

---

## 五、工程评分（1-5，附证据）

### 5.1 产品设计 (Product): 4/5

**证据**:
- README 340 行完整文档（`README.md`），含 5 种改编手法说明、V.O./O.S. 区分、3 种导出格式说明
- 5 种专业改编手法是真正的领域差异化（`prompts/adaptation_decision.md`，175 行 prompt 含铁律和偷懒过滤）
- Fountain 行业标准导出（`screenplay_exporter.py:46` `export_to_fountain()`，遵循 fountain.io 语法）
- 程序级保真度评分让作者一眼看出哪些场需要手动改（`fidelity_scorer.py` 4 维 + issues 人话清单）
- 版本树支持创作迭代（`screenplay_store.py` parent 链）

**扣分点**:
- 同步编排 30-60s（`compose.py:8-11` 明确承认 YAGNI，但对用户体验是硬伤）
- 无用户认证/多用户隔离（推断：实训营项目，单机 demo 用）

### 5.2 架构设计 (Architecture): 4/5

**证据**:
- 多 Agent 流水线分层清晰，每个 Agent 职责单一（`pipeline/` 8 个文件各司其职）
- 降级策略区分阻断/非阻断（`compose_service.py:22-29`），pipeline 健壮性好
- Prompt 与代码分离（`prompts/*.md`），5 个 prompt 文件可独立迭代
- 纯函数组装器（`yaml_composer.py` 无 LLM/DB/IO），可单测
- JSON Schema + 引用完整性双层校验（`yaml_validator.py`），产物质量有保障
- 程序级评分器不调 LLM（`fidelity_scorer.py` / `structure_analyzer.py`），可复现可单测

**扣分点**:
- 同步阻塞编排，无任务队列（`compose.py:8-11` 承认 YAGNI 但限制了长篇扩展）
- 单文件 SQLite（`config.py:66` `data/screenplay.db`），无并发写入能力
- 优化后闭环对齐逻辑复杂（`optimize.py:547-731`，`_refresh_fidelity_in_screenplay` + `_purge_orphan_decisions` + `_attach_decisions_for_new_scenes` 三段修复），耦合度高

### 5.3 工程质量 (Engineering): 4/5

**证据**:
- **234 个测试函数，5681 行测试代码**（事实，`wc -l backend/tests/*.py` + `grep -c "def test_"`），测试/生产代码比极高
- 测试覆盖端到端 smoke（`test_compose_pipeline_smoke.py` 含完整链路 + 降级链路 + 进度事件 3 类测试）
- LLM 全 mock（`conftest.py:18` 注入 dummy key，测试用 monkeypatch 替换 agent 函数）
- 依赖锁定（`requirements.txt` 全 `==`，`package.json` 用 `^` 但非 `latest`）
- 配置集中（`config.py` Settings dataclass，业务代码只 `import settings`）
- DB 迁移幂等（`connection.py:58` `_run_in_place_migrations()` 用 PRAGMA 检测列是否存在）
- 错误码体系（`compose.py:277` `_err_code_to_status()` 映射 6 种错误码到 HTTP 状态）
- 日志规范（`main.py:35` `logging.basicConfig` INFO 级别）

**扣分点**:
- API key fail-soft 而非 fail-fast（`config.py:55` placeholder key 让后端启动但 LLM 调用时报 401，`main.py:115` 仅 warning 不阻断），可能造成用户困惑（推断）
- 无类型检查工具（无 mypy.ini / ruff.toml，纯靠 Python type hints + IDE）
- 导出路由 `export.py:101-105` 有重复 `_load_parsed_screenplay` 调用（YAML 导出分支调了两次，事实，第 101 行和第 104 行）

### 5.4 可复用性 (Reuse): 4/5

**证据**:
- 8 个 pipeline Agent 模块化，每个有独立 dataclass 输入输出，可独立调用（如 `scene_splitter.py:226` `split_chapter_from_db()` 便捷入口）
- LLM 客户端通用（`llm_client.py` 可用于任何 OpenAI 兼容 API）
- YAML 组装器纯函数（`yaml_composer.py` 可用于任何结构化剧本组装场景）
- JSON Schema 可独立复用（`schemas/screenplay.json` 标准 Draft 2020-12）
- 程序级评分器（fidelity/structure）与 LLM 解耦，可独立用于任何剧本质量评估
- 导出器（Fountain/TXT/YAML）可独立用于任何符合 schema 的剧本 dict

**扣分点**:
- DB 层与 SQLite 强绑定（`ingest_service.py` / `screenplay_store.py` 直接用 `sqlite3.Connection`），切换 PG/MySQL 需重写
- 编排逻辑与 ingest/screenplay_store 紧耦合（`compose_service.py` 直接 import 三者），不易抽离为独立库

### 5.5 商业化潜力 (Commercialization): 2/5

**证据**:
- README 明确标注"七牛云 1024 暑期实训营 题目三"（`README.md`），竞赛定位
- 同步编排 30-60s，无法支撑高并发用户
- 无用户认证/配额/计费
- 无生产级部署方案（仅 Makefile dev targets + start.bat）
- 100% 新代码声明（`README.md`），0 行复用浑晶平台，合规审计友好

**加分点**:
- 5 种改编手法 + 人机协作优化是真正的产品差异化，有 SaaS 化潜力（假设）
- Fountain 行业标准导出可直接对接 Final Draft 等专业软件

---

## 六、优点

1. **多 Agent 流水线 + 降级策略**（事实，`compose_service.py:22-29`）: 区分阻断/非阻断失败，pipeline 健壮性远超一次性调用的方案。单章失败不影响其他章节产出。

2. **234 个测试函数覆盖**（事实）: 测试/生产代码比极高，包含端到端 smoke、降级链路、进度事件、YAML 校验等多维度测试。LLM 全 mock，测试可离线运行。

3. **Prompt 与代码分离**（事实，`prompts/*.md`）: 5 个 prompt 文件独立于 Python 代码，可由非技术人员（编剧/产品）独立迭代，无需改代码。

4. **程序级评分器不调 LLM**（事实，`fidelity_scorer.py` / `structure_analyzer.py`）: 可复现、免费、可单测。保真度 4 维 + 结构 3 维评分让作者一眼看出问题场景。

5. **JSON Schema 双层校验**（事实，`yaml_validator.py`）: Layer A schema 校验 + Layer B 引用完整性自检，产物质量有机器保障。错误消息中文化，方便 LLM 自动修复重试。

6. **5 种专业改编手法**（事实，`adaptation_decision.py` + `prompts/adaptation_decision.md`）: 不替作者决定，给 5 备选 + 利弊 + 推荐。V.O./动作外化/潜台词/意象化/删除覆盖了专业编剧的主要改编武器。Prompt 含"偷懒铁律"过滤占位符文本。

7. **纯函数 YAML 组装器**（事实，`yaml_composer.py`）: 无 LLM/DB/IO 副作用，ID 编号纪律严格（char_NNN / loc_NNN / scene_NNN / el_NNN_MMM / dec_NNN），可单测。

8. **版本树 + change_log 审计**（事实，`screenplay_store.py` + `optimize.py`）: 每次优化存为新版本，parent 指向上一版，optimization_log 存 change_log + reasoning，支持创作迭代回溯。

9. **依赖锁定**（事实，`requirements.txt` 全 `==`，`package.json` 非 `latest`）: 构建可复现。

10. **领域术语精确**（事实，README + `prompts/adaptation_decision.md`）: V.O. vs O.S. 区分、Fountain 语法、三幕结构、张力曲线等专业概念使用准确。

---

## 七、缺点 / 风险 / 改进优先级

### P0（高优先级）

1. **同步阻塞编排，无任务队列**（事实，`compose.py:8-11`）
   - POST `/compose-screenplay` 同步调用 30-60s，HTTP 连接长时间占用
   - 长篇小说（>20 章）可能超时
   - 改进：引入 Celery/RQ/Background Task + 轮询/WebSocket 回调
   - 注：README 和代码注释明确承认 YAGNI，这是有意识的架构取舍

2. **无用户认证/多用户隔离**（事实，全项目无 auth 中间件）
   - 任何人都可调用所有 API
   - 多用户场景下数据无隔离
   - 改进：加 JWT/API Key 中间件 + novel 表加 owner_id

### P1（中优先级）

3. **单文件 SQLite 并发限制**（事实，`config.py:66`）
   - SQLite 写入锁全库，并发 compose 会阻塞
   - 改进：迁移到 PostgreSQL 或至少 WAL 模式

4. **优化后闭环对齐逻辑复杂且耦合**（事实，`optimize.py:547-731`）
   - `_refresh_fidelity_in_screenplay` + `_purge_orphan_decisions` + `_attach_decisions_for_new_scenes` 三段修复逻辑放在 router 层
   - 应下沉到 service 层，且闭环对齐应有集成测试覆盖
   - 改进：抽到 `optimize_service.py` + 补集成测试

5. **API key fail-soft 可能造成用户困惑**（事实，`config.py:55`）
   - placeholder key `sk-NOT-SET-LLM-CALLS-WILL-FAIL` 让后端启动成功，但 LLM 功能报 401
   - 用户可能不清楚为何非 LLM 功能正常但 LLM 功能失败
   - 改进：health endpoint 已暴露 `llm_configured` 状态（`main.py:72`），前端应显式提示

6. **导出路由重复解析**（事实，`export.py:101-105`）
   - YAML 导出分支调了两次 `_load_parsed_screenplay`
   - 改进：复用第一次调用结果

### P2（低优先级）

7. **无类型检查工具配置**（推断）
   - 有 Python type hints 但无 mypy/ruff 配置文件
   - 改进：加 mypy --strict + ruff

8. **无 CI/CD 配置**（推断）
   - 无 `.github/workflows/` 或类似 CI 配置
   - 改进：加 GitHub Actions 跑 pytest + vue-tsc

9. **无 Docker 容器化**（推断）
   - 仅 Makefile + start.bat，无 Dockerfile
   - 改进：加 Dockerfile + docker-compose

---

## 八、可复用资产矩阵

| 资产 | 路径 | 可复用场景 | 复用成本 |
|---|---|---|---|
| LLM 客户端 | `backend/app/services/llm_client.py` | 任何 OpenAI 兼容 API 调用 | 低 — 通用设计 |
| JSON fence 剥离正则 | `llm_client.py:173` `_JSON_FENCE_RE` | 任何 LLM JSON 输出场景 | 极低 — 单函数 |
| YAML 双层校验器 | `backend/app/services/yaml_validator.py` | 任何结构化 YAML 校验 | 低 — schema 可替换 |
| 剧本 JSON Schema | `backend/app/schemas/screenplay.json` | 剧本结构化数据规范 | 低 — 标准 Draft 2020-12 |
| Fountain 导出器 | `screenplay_exporter.py:46` | 剧本转 Fountain 格式 | 低 — 纯函数 |
| 程序级保真度评分 | `pipeline/fidelity_scorer.py` | 剧本质量评估 | 低 — 4 维启发式 |
| 程序级结构分析 | `pipeline/structure_analyzer.py` | 剧本张力曲线分析 | 低 — 纯启发式 |
| YAML 纯函数组装器 | `pipeline/yaml_composer.py` | 结构化数据组装 + ID 编号 | 低 — 纯函数 |
| 5 种改编手法 prompt | `prompts/adaptation_decision.md` | 内心独白改编决策 | 中 — 需配合 adaptation_decision.py |
| LLM 输出校验兜底模式 | 各 pipeline agent 的 `_parse_and_validate_*` | LLM 输出结构化校验 | 中 — 需适配数据结构 |
| 指数退避重试模式 | `llm_client.py:104` | 任何可重试 API 调用 | 极低 |
| 测试 mock 模式 | `tests/conftest.py` + monkeypatch | LLM 项目测试 | 低 |

---

## 九、可学习内容

### 9.1 多 Agent LLM 流水线编排模式

`compose_service.py` 展示了如何将复杂 LLM 任务拆分为多个 Agent，每个 Agent 职责单一、输入输出明确（dataclass），编排层负责串联 + 降级。关键学习点：
- 区分阻断式 vs 非阻断式失败（第 22-29 行）
- 每层 LLM 输出都有独立校验 + 兜底（跳过非法项而非整批丢弃）
- progress_callback 事件机制（pipeline_start → chapter_done → assembling → pipeline_done）

### 9.2 LLM 输出结构化校验 + 兜底模式

每个 pipeline agent 的 `_parse_and_validate_*` 函数展示了如何处理 LLM 不可靠输出：
- 枚举校验 + 非法值默认替换（`scene_splitter.py:164-170`）
- 范围越界截断到合法区间（`scene_splitter.py:182-184`）
- 长度截断对齐 schema（`element_extractor.py:208-215`）
- aka 映射 + 编造角色过滤（`element_extractor.py:226-230`）
- 字段缺失兜底（`adaptation_decision.py:224-228`）

### 9.3 Prompt 工程最佳实践

`prompts/adaptation_decision.md`（175 行）展示了高质量 prompt 的写法：
- 明确角色定位 + 任务说明
- 输入/输出 JSON 结构示例
- "铁律"式约束（5 选项缺一不可、text 必须 >= 20 字）
- "偷懒铁律"过滤占位符（后端会过滤 text 少于 8 字的选项）
- 边界条件说明（空数组 → 返空、超长 → 精炼）

### 9.4 程序级启发式评分替代 LLM 调用

`fidelity_scorer.py` 和 `structure_analyzer.py` 展示了如何用程序级启发式替代 LLM 评分：
- 优势：可复现、免费、可单测、快
- 4 维保真度评分（对白覆盖度/角色对齐/元素密度/决策完整度）有明确的理想区间和扣分逻辑
- 张力曲线 5 信号加权 + 三幕分区 + 关键节点定位

### 9.5 JSON Schema + 引用完整性双层校验

`yaml_validator.py` 展示了如何用 JSON Schema Draft 2020-12 做结构校验 + 自写引用完整性校验：
- Layer A：schema 层（类型/枚举/正则/必填）
- Layer B：引用层（character_id/location_id/scene_id/element_id 跨节点引用 + 唯一性）
- 错误消息中文化（`_humanize_schema_error()`）

### 9.6 版本树 + change_log 审计

`screenplay_store.py` + `optimize.py` 展示了如何用 parent_screenplay_id 链实现版本树：
- 每次优化存为新版本
- optimization_log 存 change_log + reasoning + fallback_reason
- 前端可回溯子版本优化记录（`stores/screenplay.ts:342`）

### 9.7 端到端 smoke 测试模式

`test_compose_pipeline_smoke.py` 展示了如何测试多 Agent 流水线：
- 走真实 parser + ingest_service 链路（非 mock）
- LLM agent 用 monkeypatch 全 mock
- 测试矩阵：完整链路 + 降级链路 + 进度事件 + fidelity 写入

---

## 十、YAML 摘要

```yaml
project: hunjing-screenplay
one_line_judgment: 多 Agent LLM 流水线 + 程序级启发式评分的小说转剧本工具，工程成熟度最高，但同步编排和单文件 SQLite 限制可扩展性
product_type: 小说自动转剧本的结构化创作辅助工具（AI Pipeline + 人机协作优化）
target_users: 编剧/小说作者/影视专业学生
core_loop: 上传小说 → 生成故事圣经 → 多 Agent 流水线（切场景→抽元素→归属精修→改编决策→保真度评分）→ 组装 YAML → 人机协作优化 → 版本树管理 → 三格式导出
architecture_style: 分层管道式（Pipeline + Service Layer），FastAPI 单体同步编排
stack:
  backend: FastAPI 0.115 + Python 3.11 + SQLite + DeepSeek V3（OpenAI 兼容）
  frontend: Vue 3.5 + TypeScript + Pinia 3 + Vite 5
  testing: pytest 8.3.3 + httpx（234 个测试函数）
  schema: JSON Schema Draft 2020-12 + PyYAML + jsonschema
strongest_patterns:
  - 多 Agent LLM 流水线 + 阻断/非阻断降级策略
  - 每层 LLM 输出独立校验 + 兜底（跳过非法项不丢整批）
  - Prompt 与代码分离（5 个 .md 文件）
  - 程序级启发式评分替代 LLM（fidelity 4 维 + structure 3 维）
  - JSON Schema + 引用完整性双层校验
  - 纯函数 YAML 组装器（无副作用，ID 编号纪律严格）
  - 版本树 + change_log 审计
  - 5 种专业改编手法 + 偷懒铁律过滤
  - 234 个测试函数 + LLM 全 mock
main_risks:
  - P0: 同步阻塞编排 30-60s，无任务队列
  - P0: 无用户认证/多用户隔离
  - P1: 单文件 SQLite 并发限制
  - P1: 优化后闭环对齐逻辑复杂且耦合在 router 层
  - P1: API key fail-soft 可能造成用户困惑
  - P1: 导出路由重复解析
business_scenarios:
  - 七牛云 1024 暑期实训营竞赛项目（demo 演示 + 评委复现）
  - 编剧辅助创作（短篇小说转剧本）
  - 影视专业教学工具（剧本结构分析 + 改编手法学习）
reusable_assets:
  - llm_client.py（通用 OpenAI 兼容客户端）
  - yaml_validator.py（双层 YAML 校验模式）
  - screenplay.json（剧本 JSON Schema 标准）
  - screenplay_exporter.py（Fountain/TXT/YAML 导出）
  - fidelity_scorer.py（程序级 4 维保真度评分）
  - structure_analyzer.py（张力曲线 + 三幕分析）
  - yaml_composer.py（纯函数 YAML 组装 + ID 编号）
  - adaptation_decision.md（5 种改编手法 prompt）
non_reusable_parts:
  - DB 层与 SQLite 强绑定
  - 编排逻辑与 ingest/screenplay_store 紧耦合
  - 无认证/配额/计费体系
scores:
  product: 4
  architecture: 4
  engineering: 4
  reuse: 4
  commercialization: 2
evidence:
  - compose_service.py:22-29 — 降级策略区分阻断/非阻断
  - compose_service.py:117 — orchestrate_full_pipeline 端到端编排
  - llm_client.py:104 — 指数退避 time.sleep(2 ** attempt)
  - llm_client.py:173 — _JSON_FENCE_RE 正则剥离 markdown fence
  - yaml_validator.py:100 — validate_screenplay_yaml 双层校验
  - yaml_validator.py:190 — _validate_references 引用完整性自检
  - fidelity_scorer.py:93-98 — 4 维权重 dialogue_coverage 0.30/character_alignment 0.30/element_density 0.20/decision_completeness 0.20
  - structure_analyzer.py:184-241 — 张力 5 信号加权
  - adaptation_decision.py:80 — 5 种改编手法枚举
  - adaptation_decision.py:296 — _options_complete 兼容 legacy 3 种
  - scene_splitter.py:152 — _parse_and_validate_scenes 枚举校验 + 范围截断
  - element_extractor.py:182 — _parse_and_validate_elements aka 映射 + 编造角色过滤
  - screenplay_store.py:36 — save_screenplay 支持 parent_screenplay_id 版本树
  - optimize.py:547-731 — 优化后闭环对齐三段修复
  - config.py:55 — placeholder key fail-soft 模式
  - compose.py:8-11 — 同步编排 YAGNI 取舍说明
  - export.py:101-105 — YAML 导出重复解析
  - tests/conftest.py:18 — 测试 dummy key 注入
  - requirements.txt — 全 == 版本锁定
  - package.json — Vue 3.5 + Pinia 3 非 latest
  - 234 个测试函数 / 5681 行测试代码
confidence: high
```

---

## 审查结论

hunjing-screenplay 是 5 个受审项目中**工程成熟度最高**的一个。其核心优势在于：多 Agent 流水线的降级策略设计、234 个测试函数的覆盖深度、Prompt 与代码分离的工程纪律、以及程序级启发式评分替代 LLM 调用的成本控制。5 种专业改编手法 + 版本树 + 人机协作优化构成真正的产品差异化。

主要短板是同步编排架构（YAGNI 取舍）和单文件 SQLite 的并发限制，但这些都是竞赛项目定位下的合理取舍。如果要商业化，需要引入任务队列 + 用户认证 + 数据库迁移 + 容器化部署。
