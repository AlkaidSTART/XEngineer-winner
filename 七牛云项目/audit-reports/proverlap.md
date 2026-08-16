# proverlap 项目审计报告

> 一句话判断：proverlap 是一个架构成熟的"双模型交叉验证 PR 审查"服务，其"维度×模型矩阵 + 交叉比对打分 + 三级分级 + 三种阻塞模式"设计完整且有测试覆盖，但 API 端点无鉴权、模型名硬编码、Redis/MyBatis-Plus 配置但未使用是明显短板。

---

## 一、项目边界确认

### 1.1 项目定位（事实）

PRoverlap 是一个多模型交叉审查 GitHub Pull Request 的自动化工具。安装为 GitHub App 后，每个 PR 事件触发时用两个不同模型独立审查同一段代码，共识输出高置信度发现，分歧标注两个视角供人类复核。

- README：`/Users/allure/Desktop/七牛云项目/proverlap/README.md` 第 1-3 行
- AGENTS.md：`/Users/allure/Desktop/七牛云项目/proverlap/AGENTS.md` 第 5-9 行
- 入口：`/Users/allure/Desktop/七牛云项目/proverlap/proverlap-server/src/main/java/io/github/spojchil/proverlap/ProverlapApplication.java`

### 1.2 目录结构（事实）

```
proverlap/
├── proverlap-server/                          # 主服务模块
│   ├── pom.xml                               # 子模块 POM
│   └── src/
│       ├── main/
│       │   ├── java/io/github/spojchil/proverlap/
│       │   │   ├── ProverlapApplication.java  # Spring Boot 入口
│       │   │   ├── webhook/                   # Webhook 接收 + HMAC 验签
│       │   │   │   ├── WebhookController.java  (96 行)
│       │   │   │   └── WebhookValidator.java    (72 行)
│       │   │   ├── tier/                      # Tier 分级器
│       │   │   │   └── TierClassifier.java     (110 行)
│       │   │   ├── context/                   # 上下文组装
│       │   │   │   └── ContextBuilder.java     (144 行)
│       │   │   ├── review/                     # 审查引擎
│       │   │   │   ├── ReviewOrchestrator.java  (271 行)
│       │   │   │   ├── DimensionReviewer.java  (319 行)
│       │   │   │   ├── CrossValidator.java     (144 行)
│       │   │   │   ├── FindingParser.java      (95 行)
│       │   │   │   └── prompts/                # 7 个维度 Prompt
│       │   │   │       ├── ReviewPrompt.java   (接口)
│       │   │   │       ├── SecurityPrompt.java
│       │   │   │       ├── CorrectnessPrompt.java
│       │   │   │       ├── DesignPrompt.java
│       │   │   │       ├── PerformancePrompt.java
│       │   │   │       ├── MaintainabilityPrompt.java
│       │   │   │       ├── TestCoveragePrompt.java
│       │   │   │       ├── PrSummaryPrompt.java
│       │   │   │       └── CrossValidationCommentFormatter.java (79 行)
│       │   │   ├── aggregation/                # 结果聚合
│       │   │   │   └── ResultAggregator.java   (120 行)
│       │   │   ├── output/                     # API 端点
│       │   │   │   └── ReviewController.java  (96 行)
│       │   │   ├── config/                     # 配置
│       │   │   │   ├── LLMConfig.java          (70 行)
│       │   │   │   ├── GitHubClient.java       (471 行)
│       │   │   │   ├── GitHubClientConfig.java
│       │   │   │   ├── GitHubProperties.java
│       │   │   │   ├── ModelProperties.java
│       │   │   │   ├── AsyncConfig.java        (28 行)
│       │   │   │   ├── TierProperties.java
│       │   │   │   ├── ContextProperties.java
│       │   │   │   ├── MybatisPlusConfig.java
│       │   │   │   └── MybatisMetaObjectHandler.java
│       │   │   ├── model/                     # DTO / 枚举 / 实体
│       │   │   │   ├── dto/ (Finding, ReviewResult, WebhookPayload, CrossValidationResult)
│       │   │   │   ├── entity/ (BaseEntity)
│       │   │   │   └── enums/ (ReviewMode, TierLevel)
│       │   │   └── mapper/                    # 仅 .gitkeep
│       │   └── resources/application.yml
│       └── test/                               # 8 个测试文件
│           └── java/.../proverlap/
│               ├── review/ (ReviewOrchestratorTest, DimensionReviewerTest, FindingParserTest)
│               ├── webhook/ (WebhookValidatorTest)
│               ├── tier/ (TierClassifierTest)
│               ├── aggregation/ (ResultAggregatorTest)
│               ├── context/ (ContextBuilderTest)
│               └── config/ (GitHubClientTest)
├── scripts/                                   # Python CLI
│   ├── review.py                              (98 行)
│   └── requirements.txt
├── docs/                                      # 4 份设计文档
├── .github/workflows/ci.yml                   # CI/CD
├── Dockerfile                                 # 多阶段构建
├── docker-compose.yml                         # PG + Redis + App
├── pom.xml                                    # 父 POM
├── README.md, AGENTS.md, CONTRIBUTING.md
└── .env.example, .gitignore
```

- 总 Java 代码量：4198 行（含测试 ~1343 行，主代码 ~2855 行）
- 8 个测试文件

### 1.3 技术栈（事实）

| 层 | 技术 | 来源 |
|---|---|---|
| 语言 | Java 21 | `pom.xml` 第 25 行 |
| 框架 | Spring Boot 4.0.6 | `pom.xml` 第 21 行 |
| LLM 集成 | LangChain4j 1.15 (OpenAI 兼容) | `pom.xml` 第 30 行 |
| 异步 | CompletableFuture + 虚拟线程 (Java 21) | `AsyncConfig.java` 第 26 行 |
| 数据库 | PostgreSQL 16 + MyBatis-Plus 3.5.15 | `pom.xml` 第 33-34 行, `docker-compose.yml` |
| 缓存 | Redis 7 | `docker-compose.yml` 第 21 行 |
| GitHub 集成 | 自建轻量 REST 客户端 (RestClient) | `GitHubClient.java` |
| 部署 | Docker Compose (多阶段构建) | `Dockerfile`, `docker-compose.yml` |
| CI/CD | GitHub Actions | `.github/workflows/ci.yml` |
| 代码风格 | Spotless + google-java-format | `AGENTS.md` 第 84 行 |
| 测试 | JUnit 5 + Mockito + Testcontainers | `pom.xml` 第 43-127 行 |

---

## 二、用户/产品回路还原

### 2.1 目标用户（事实）

GitHub 仓库维护者，希望用 AI 自动审查 PR，减少人工 review 负担。

### 2.2 核心产品回路（事实）

```
PR 事件 (Webhook) 或 API 请求
  ↓
HMAC 验签 → 解析 PR 信息 (owner/repo/number/sha/title)
  ↓
Tier 分级 (diff 行数 + 敏感文件 → T1/T2/T3)
  ↓
PR 类型解析 (Conventional Commits → feat/fix/perf/...)
  ↓
上下文组装 (规范文件 + 变更文件完整内容 + diff)
  ↓
多维度并行审查 (CompletableFuture + 虚拟线程)
  ├── 安全性 (双模型交叉验证) ──┐
  ├── 正确性 (双模型交叉验证) ──┤
  ├── 设计与架构 (单模型)       │
  ├── 性能 (单模型)             │
  ├── 可维护性 (单模型)         │
  └── 测试覆盖 (单模型)         │
       ↓                       ↓
  FindingParser 解析 JSON    CrossValidator 比对
       ↓                       ↓
  ResultAggregator 去重 + 排序 + 摘要
       ↓
  Review Comment (摘要) + Check Run (完整报告)
```

- Webhook 入口：`WebhookController.java` 第 42-95 行 `handleWebhook()`
- HMAC 验签：`WebhookValidator.java` 第 36-50 行 `verify()`
- 异步审查：`ReviewOrchestrator.java` 第 65-127 行 `review()` (@Async)
- 同步审查：`ReviewOrchestrator.java` 第 132-164 行 `reviewSync()`
- Tier 分级：`TierClassifier.java` 第 58-85 行 `classify()`
- 上下文组装：`ContextBuilder.java` 第 44-68 行 `build()`
- 维度审查：`DimensionReviewer.java` 第 115-140 行 `review()`
- 交叉比对：`CrossValidator.java` 第 33-96 行 `compare()`
- 结果聚合：`ResultAggregator.java` 第 31-73 行 `aggregate()`

### 2.3 三种审查模式（事实）

`ReviewMode` 枚举（`ReviewMode.java` 第 11-15 行）：

| 模式 | 行为 | Check Run | 代码位置 |
|---|---|---|---|
| `COMMENT_ONLY` | 仅评论，不阻塞 | 不创建 | `ReviewOrchestrator.java` 第 75 行 |
| `BLOCK_UNTIL_REVIEWED` | 审查完成前阻塞 | 审查完即 success | 第 113-115 行 |
| `BLOCK_ON_FINDINGS` | 有阻断级问题时阻塞 | 阻断→failure / 无阻断→success | 第 113-114 行 |

---

## 三、技术架构还原

### 3.1 整体架构（事实）

```
┌─────────────────────────────────────────────────────────────┐
│                     GitHub Platform                           │
│  PR Event → Webhook (HMAC-SHA256) / REST API                  │
└────────────┬──────────────────────────────┬─────────────────┘
             │                                │
             ▼                                ▼
┌────────────────────────┐       ┌────────────────────────────┐
│  WebhookController      │       │  ReviewController          │
│  POST /webhook/github   │       │  POST /api/review          │
│  HMAC 验签 → 异步触发    │       │  URL 解析 → 同步返回        │
└───────────┬────────────┘       └──────────┬─────────────────┘
            │                                │
            ▼                                ▼
┌─────────────────────────────────────────────────────────────┐
│                   ReviewOrchestrator                          │
│  @Async("reviewExecutor") 虚拟线程                            │
│  ┌─────────────────────────────────────────────────────┐     │
│  │ 1. getPullRequestDiff (GitHubClient)                 │     │
│  │ 2. Tier 分级 (TierClassifier)                        │     │
│  │ 3. 上下文组装 (ContextBuilder)                       │     │
│  │ 4. 多维度并行审查 (DimensionReviewer)                │     │
│  │ 5. 结果聚合 (ResultAggregator)                       │     │
│  │ 6. 输出 (postReview + updateCheckRun)                │     │
│  └─────────────────────────────────────────────────────┘     │
└──────────┬───────────────────────────────────┬───────────────┘
           │                                   │
           ▼                                   ▼
┌────────────────────────┐       ┌────────────────────────────┐
│   DimensionReviewer     │       │   GitHubClient              │
│  维度×模型矩阵调度       │       │  JWT RS256 → 安装令牌       │
│  ┌──────────────────┐   │       │  令牌缓存 50min (DCL)       │
│  │ 双模型 CV:        │   │       │  PR diff / 文件内容         │
│  │  security+correct │   │       │  Check Run / Review        │
│  │ 单模型:           │   │       └────────────────────────────┘
│  │  design+perf+     │   │
│  │  maintain+test    │   │
│  └──────────────────┘   │
│  CompletableFuture并行  │
│  虚拟线程执行器           │
│  超时控制                 │
└──────────┬──────────────┘
            │
   ┌────────┴────────┬───────────────┐
   ▼                 ▼               ▼
┌─────────┐  ┌──────────────┐  ┌─────────────┐
│Model A  │  │  Model B     │  │ CrossValidator│
│(主审查) │  │ (交叉验证)    │  │ 比对打分     │
│LangChain│  │ LangChain4j  │  │ 共识/分歧    │
│4j      │  │              │  │ 单模型发现   │
└─────────┘  └──────────────┘  └─────────────┘
```

### 3.2 核心架构模式：双模型交叉验证（事实）

`CrossValidator.java` 第 17-144 行 — 核心创新点：

- **匹配打分**（第 106-130 行 `matchScore()`）：
  - 文件不同 → 0（不匹配）
  - 行号邻近（±5 行）→ +2，不邻近 → 0
  - 严重度相同 → +1
  - 标题关键词匹配（>3 字符共同词）→ +1
  - 满分 4 分
- **分类**：
  - ≥3 分 → **共识**（高置信，双模型一致）——第 59-67 行
  - =2 分 → **分歧**（需人类判断，双视角标注）——第 68-74 行
  - 未匹配 → **单模型发现**（中置信，需人类复核）——第 75-77/81-85 行

### 3.3 维度×模型矩阵调度（事实）

`DimensionReviewer.java` 第 275-298 行 `buildMatrix()`：

| PR 类型 | 维度任务（模型数） |
|---|---|
| feat | design(1) + correctness(2) + security(2) + maintainability(1) + test(1) |
| fix | correctness(2) + security(2) |
| perf | correctness(2) + performance(1) |
| refactor | correctness(2) + maintainability(1) |
| test | test(1) |
| docs/style/chore/build/ci | (空，跳过) |

- PR 类型解析：第 200-219 行 `parseType()`，三层匹配：Conventional Commits → Issue 引用 → 祈使动词映射
- Tier 过滤：第 222-241 行 `selectTasks()`：T1 只保留第一个单模型维度，T2 跳过 design，T3 全维度

### 3.4 GitHub App 认证流程（事实）

`GitHubClient.java` 第 296-369 行：

```
私钥 + App ID → JWT (RS256, 10min 有效) → 安装访问令牌 (60min, 缓存 50min) → REST API
```

- **令牌缓存**（第 303-316 行 `obtainToken()`）：ConHashMap 快速无锁读 + synchronized DCL 刷新，按 installationId 分别缓存
- **JWT 自实现**（第 339-369 行 `generateJwt()`）：使用 Java 标准库 `Signature.getInstance("SHA256withRSA")`，不依赖外部 JWT 库
- **PKCS#1 DER 解析**（第 416-440 行 `parsePkcs1()`）：自建 DER 序列解析器，解析 9 个 INTEGER 字段构建 RSAPrivateCrtKeySpec，PKCS#1 解析失败时自动回退 PKCS#8
- **双通道认证**（第 86-117 行 `getPullRequestDiff()`）：优先 Installation Token，回退 PAT

### 3.5 虚拟线程并行审查（事实）

`AsyncConfig.java` 第 24-27 行：`Executors.newVirtualThreadPerTaskExecutor()`

- `ReviewOrchestrator.java` 第 94-97 行：审查与摘要 `CompletableFuture.supplyAsync` 并行
- `DimensionReviewer.java` 第 162-165 行：双模型 `CompletableFuture.supplyAsync` 并行
- `DimensionReviewer.java` 第 132-139 行：超时控制 `f.get(timeoutSeconds, TimeUnit.SECONDS)`

### 3.6 上下文组装（事实）

`ContextBuilder.java` 第 44-68 行 `build()`：

1. **规范文件**（第 27-28 行）：CLAUDE.md、CONTRIBUTING.md、.editorconfig
2. **变更文件完整内容**（第 88-107 行）：按 CODE_EXTENSIONS 过滤，限 maxFiles 个，每文件限 maxFileLines 行
3. **diff 文本**（第 56-61 行）：超 maxDiffSize 截断
- **路径遍历防护**（第 116 行）：`if (!path.contains(".."))` 过滤含 `..` 的路径
- **大小限制**（`application.yml` 第 60-64 行）：maxFiles=10, maxFileLines=3000, maxDiffSize=80000, maxContextSize=120000

---

## 四、工程质量评估

### 4.1 评分总览

| 维度 | 评分 | 依据 |
|---|---|---|
| 架构设计 | 5/5 | 交叉验证 + 维度矩阵 + 三级分级 + 三种模式，核心创新完整 |
| 代码质量 | 4/5 | DCL 缓存、PKCS#1 解析、虚拟线程，但模型名硬编码 |
| 测试覆盖 | 4/5 | 8 个测试文件覆盖核心逻辑，但无集成测试 |
| 安全性 | 3/5 | HMAC 常量时间比较、路径遍历防护，但 API 无鉴权 |
| 可维护性 | 4/5 | 职责分包清晰，但 Redis/MyBatis 未使用 |
| 文档质量 | 5/5 | README + AGENTS.md + 4 份设计文档 + CONTRIBUTING |
| 可复现性 | 4/5 | Docker Compose 一键启动，但需配置模型 API Key |
| **综合** | **4.1/5** | |

### 4.2 架构设计（5/5）——证据

**正面：**
- 双模型交叉验证是核心创新——共识=高置信，分歧=双视角标注（`CrossValidator.java` 第 17-144 行）——事实
- 维度×模型矩阵调度，PR 类型驱动维度选择（`DimensionReviewer.java` 第 275-298 行）——事实
- 三级 Tier 分级，diff 大小 + 敏感文件双维度（`TierClassifier.java` 第 58-85 行）——事实
- 三种审查模式，支持 Check Run 阻塞合并（`ReviewOrchestrator.java` 第 72-118 行）——事实
- 双入口设计：Webhook 异步 + API 同步（`WebhookController.java` + `ReviewController.java`）——事实
- 上下文组装完整：规范文件 + 文件完整内容 + diff（`ContextBuilder.java` 第 44-68 行）——事实
- Finding 去重：同文件 + 行号 ±5 + 同严重度（`ResultAggregator.java` 第 80-112 行）——事实

### 4.3 代码质量（4/5）——证据

**正面：**
- 令牌缓存 DCL 模式：ConHashMap 无锁读 + synchronized 刷新（`GitHubClient.java` 第 303-316 行）——事实
- PKCS#1 DER 自建解析器，PKCS#1 失败自动回退 PKCS#8（`GitHubClient.java` 第 384-413 行）——事实
- 虚拟线程并行 LLM 调用（`AsyncConfig.java` 第 26 行）——事实
- CompletableFuture 超时控制（`DimensionReviewer.java` 第 134 行）——事实
- PR 类型三层解析：Conventional Commits → Issue 引用 → 祈使动词（`DimensionReviewer.java` 第 200-219 行）——事实
- Docker 非 root 用户（`Dockerfile` 第 33 行 `USER proverlap`）——事实
- Docker 多阶段构建，Maven 缓存层优化（`Dockerfile` 第 16-23 行）——事实

**负面（P2）：**
- `CrossValidationCommentFormatter.java` 第 32-33/37/45 行硬编码 "DeepSeek" 和 "mimo" 模型名，而非使用 `Finding.modelSource` 或动态配置——事实
- `ReviewOrchestrator.java` 第 270 行 `taskDimension()` 对所有 future 返回 "unknown"，超时日志中维度名丢失——事实
- `GitHubClient.java` 第 203 行 `uri += "?ref=" + ref` 字符串拼接构造 URI，ref 未做 URL 编码——事实

### 4.4 测试覆盖（4/5）——证据

8 个测试文件 ~1343 行：
- `WebhookValidatorTest.java`（109 行）：有效/无效签名、错误密钥、null、缺前缀、空 body、Unicode——事实
- `ReviewOrchestratorTest.java`（246 行）：异步/同步流程、空 diff、异常处理、三种 Check Run 模式——事实
- `DimensionReviewerTest.java`（204 行）：维度矩阵调度、PR 类型解析——事实
- `FindingParserTest.java`（112 行）：JSON 解析、markdown 代码块提取——事实
- `TierClassifierTest.java`（131 行）：三级分级、敏感文件检测——事实
- `ResultAggregatorTest.java`（156 行）：去重、排序、统计——事实
- `ContextBuilderTest.java`（199 行）：上下文组装、截断、路径过滤——事实
- `GitHubClientTest.java`（181 行）：JWT 生成、PKCS#1/PKCS#8 解析、令牌缓存——事实

**负面：**
- AGENTS.md 第 93 行声称"集成测试使用 Testcontainers"，但 pom.xml 声明了 Testcontainers 依赖（第 109-127 行），实际无集成测试文件——事实
- 无端到端测试（Webhook → 审查 → Check Run 完整链路）——推断

### 4.5 安全性（3/5）——证据

**正面：**
- Webhook HMAC-SHA256 验签，`MessageDigest.isEqual` 常量时间比较防时序攻击（`WebhookValidator.java` 第 45 行）——事实
- 路径遍历防护：`extractFiles` 过滤含 `..` 的路径（`ContextBuilder.java` 第 116 行）——事实
- Docker 非 root 用户运行（`Dockerfile` 第 33 行）——事实
- `.gitignore` 覆盖 `.env`、`*.pem`、`*.key`（第 2-4 行）——事实
- `.env.example` 全部为占位符，无真实密钥（全文）——事实
- JWT 10 分钟有效期，安装令牌 50 分钟缓存（`GitHubClient.java` 第 42-43 行）——事实

**负面（P2）：**
- `POST /api/review` 端点无任何鉴权或速率限制（`ReviewController.java` 第 47-85 行），任何人可触发昂贵的 LLM 调用——事实
- `scripts/review.py` 第 42 行 `verify=False` 禁用 TLS 证书验证——事实
- `docker-compose.yml` 第 8 行 PostgreSQL 默认密码 "proverlap"——事实

### 4.6 文档质量（5/5）——证据

**正面：**
- README 182 行：Demo 链接、配置、快速开始、核心特性、工作原理、审查流程图、技术栈、项目结构、文档索引——事实
- AGENTS.md 122 行：项目概述、技术栈表、项目结构、常用命令、代码风格、测试规范、Commit 规范、PR 流程——事实
- 4 份设计文档：`docs/project-design.md`、`docs/dimension-design.md`、`docs/decisions.md`、`docs/todo.md`——事实
- CONTRIBUTING.md 贡献指南——事实
- .gitmessage Commit 模板——事实
- PR 模板：`.github/pull_request_template.md`——事实

**负面（P3）：**
- AGENTS.md 第 30 行引用 `PrReviewApplication.java`，实际文件名为 `ProverlapApplication.java`——事实
- AGENTS.md 第 48-50 行引用 `.claude/skills/` 和 `.agents/skills/` 目录，实际不存在——事实

---

## 五、优点

1. **双模型交叉验证架构**（事实）：两个模型独立审查同一段代码，共识=高置信，分歧=双视角标注。这是区别于单模型审查方案的核心创新（`CrossValidator.java` 第 17-144 行）

2. **维度×模型矩阵调度**（事实）：PR 类型驱动维度选择，安全+正确性用双模型 CV，其余维度单模型，资源精准分配（`DimensionReviewer.java` 第 275-298 行）

3. **三级 Tier 分级**（事实）：diff 大小 + 敏感文件双维度判定，T1 快速通道→T2 标准审查→T3 深度审查，自动调节审查深度（`TierClassifier.java` 第 58-85 行）

4. **三种阻塞模式**（事实）：COMMENT_ONLY / BLOCK_UNTIL_REVIEWED / BLOCK_ON_FINDINGS，灵活控制审查对合并的影响（`ReviewOrchestrator.java` 第 72-118 行）

5. **GitHub App 认证自实现**（事实）：JWT RS256 + PKCS#1/PKCS#8 DER 解析 + 令牌缓存 DCL，不依赖外部 JWT 库（`GitHubClient.java` 第 303-440 行）

6. **虚拟线程并行审查**（事实）：Java 21 虚拟线程 + CompletableFuture，每任务一线程，I/O 阻塞自动让出（`AsyncConfig.java` 第 26 行）

7. **HMAC 常量时间比较**（事实）：`MessageDigest.isEqual` 防止时序攻击（`WebhookValidator.java` 第 45 行）

8. **路径遍历防护**（事实）：`extractFiles` 过滤含 `..` 的路径（`ContextBuilder.java` 第 116 行）

9. **完善的测试覆盖**（事实）：8 个测试文件覆盖核心逻辑（HMAC 验签、交叉比对、去重、Tier 分级、上下文组装、JWT 生成）

10. **Docker 多阶段构建 + 非 root 用户**（事实）：Maven 编译 → JRE 运行，分离构建与运行环境，安全性高（`Dockerfile`）

11. **CI/CD 自动化**（事实）：GitHub Actions 编译 + 测试 + Docker 镜像版本化推送至 GHCR（`.github/workflows/ci.yml`）

12. **双入口设计**（事实）：Webhook 异步自动触发 + API 同步手动调用，覆盖不同使用场景

---

## 六、缺点与风险

### P2 级（应改进）

1. **API 端点无鉴权**（事实）：`POST /api/review` 无任何认证或速率限制，任何人可触发昂贵的 LLM 调用（`ReviewController.java` 第 47-85 行）

2. **模型名硬编码**（事实）：`CrossValidationCommentFormatter.java` 第 32-33/37/45 行硬编码 "DeepSeek" 和 "mimo"，而非使用 `Finding.modelSource` 或动态模型名

3. **CLI 禁用 TLS 验证**（事实）：`scripts/review.py` 第 42 行 `verify=False`，虽有 PyOpenSSL 注入说明（第 17-19/27 行注释解释 GFW 阻断），但禁用证书验证存在中间人攻击风险

4. **Redis 配置但未使用**（事实）：`docker-compose.yml` 第 21-30 行配置 Redis，`application.yml` 第 15-19 行配置 Redis 连接，但代码中无任何 Redis 使用——推断

5. **MyBatis-Plus 配置但无 Mapper**（事实）：`MybatisPlusConfig.java` 和 `MybatisMetaObjectHandler.java` 已配置，`application.yml` 第 22-31 行配置 MyBatis-Plus，但 `mapper/` 目录仅含 `.gitkeep`，无实际 Mapper——事实

6. **PostgreSQL 默认密码**（事实）：`docker-compose.yml` 第 8 行 `POSTGRES_PASSWORD: proverlap`

### P3 级（可优化）

7. **taskDimension 返回 unknown**（事实）：`ReviewOrchestrator.java` 第 270 行 `taskDimension()` 对所有 future 返回 "unknown"，超时日志中丢失维度名

8. **URI 字符串拼接**（事实）：`GitHubClient.java` 第 203 行 `uri += "?ref=" + ref`，ref 未做 URL 编码

9. **AGENTS.md 文件名不一致**（事实）：第 30 行 `PrReviewApplication.java` 与实际 `ProverlapApplication.java` 不符

10. **AGENTS.md 引用不存在的目录**（事实）：第 48-50 行引用 `.claude/skills/` 和 `.agents/skills/`，实际不存在

11. **Testcontainers 声明但无集成测试**（事实）：`pom.xml` 第 109-127 行声明 Testcontainers 依赖，AGENTS.md 第 93 行声称使用，但无集成测试文件

12. **extractFiles 仅解析 +++ b/**（事实）：`ContextBuilder.java` 第 110-122 行仅从 `+++ b/` 提取文件，漏掉删除文件（`--- a/`）和重命名场景

13. **无 API 文档**（推断）：`ReviewController.java` 有 Javadoc 说明请求格式，但无 OpenAPI/Swagger 集成

---

## 七、可复用性矩阵

| 模块 | 可复用场景 | 复用成本 | 备注 |
|---|---|---|---|
| 双模型交叉验证算法 | 任何多模型/多审查器比对场景 | 低 | `CrossValidator.java` 打分+分类逻辑 |
| 维度×模型矩阵调度 | 任何 PR 类型驱动多维度审查 | 低 | `DimensionReviewer.java` buildMatrix |
| Tier 分级器 | 任何基于 diff 大小+文件敏感度的分级 | 低 | `TierClassifier.java` |
| GitHub App JWT 认证 | 任何 GitHub App 后端服务 | 中 | `GitHubClient.java` PKCS#1/PKCS#8 解析 |
| 令牌缓存 DCL 模式 | 任何按 ID 缓存令牌的场景 | 低 | `GitHubClient.java` obtainToken |
| HMAC 验签模式 | 任何 Webhook 签名验证 | 低 | `WebhookValidator.java` |
| 上下文组装模式 | 任何 LLM 代码审查上下文构建 | 低 | `ContextBuilder.java` |
| Finding 去重算法 | 任何审查发现去重 | 低 | `ResultAggregator.java` |
| 虚拟线程并行模式 | 任何 Java 21 并行 I/O | 低 | `AsyncConfig.java` |
| Docker 多阶段构建 | 任何 Java 项目容器化 | 低 | `Dockerfile` |
| CI/CD 版本化镜像推送 | 任何 GitHub Actions + GHCR | 低 | `.github/workflows/ci.yml` |
| PR 类型三层解析 | 任何 Conventional Commits 解析 | 低 | `DimensionReviewer.java` parseType |

---

## 八、学习内容提取

### 8.1 架构设计学习

1. **双模型交叉验证**：两个模型独立审查同一段代码，通过文件+行号+严重度+关键词四维度打分匹配。共识（≥3分）=高置信度，分歧（=2分）=双视角标注，未匹配=单模型发现。这比单模型审查提供了置信度分层。

2. **维度×模型矩阵**：不是所有维度都用双模型（成本高），而是安全+正确性用双模型 CV，设计/性能/可维护性/测试用单模型。PR 类型（feat/fix/perf）进一步驱动维度选择，资源精准分配。

3. **三级 Tier 分级**：T1 快速通道（小 diff + 非代码）→ T2 标准审查 → T3 深度审查（大 diff 或敏感文件）。敏感文件模式包括 auth/security/sql/migration/flyway/liquibase 目录 + Security/Auth/Login/Password 文件名。

4. **三种阻塞模式**：COMMENT_ONLY（不阻塞）→ BLOCK_UNTIL_REVIEWED（审查完即放行）→ BLOCK_ON_FINDINGS（有阻断才阻塞）。README 推荐 BLOCK_UNTIL_REVIEWED，因为 BLOCK_ON_FINDINGS "仍有误报率"。

### 8.2 GitHub 工程学习

5. **GitHub App JWT 认证流程**：私钥 + App ID → JWT (RS256, 10min) → 安装访问令牌 (60min) → REST API。令牌按 installationId 缓存，DCL 模式保证多线程安全。

6. **PKCS#1 vs PKCS#8 私钥解析**：PKCS#1（BEGIN RSA PRIVATE KEY）需自建 DER 解析器，PKCS#8（BEGIN PRIVATE KEY）用标准 PKCS8EncodedKeySpec。实际场景中可能出现"PKCS#1 头 + PKCS#8 内容"的误标注，需自动回退。

7. **Check Run 阻塞合并**：创建 Check Run (in_progress) → 审查完成 → 更新 conclusion (success/failure/neutral)。BLOCK_ON_FINDINGS 模式下有阻断→failure（阻止合并），无阻断→success。

### 8.3 安全工程学习

8. **HMAC 常量时间比较**：`MessageDigest.isEqual()` 做常量时间比较，防止时序攻击。不要用 `String.equals()` 比较 HMAC 签名。

9. **路径遍历防护**：从 diff 提取文件路径时，过滤含 `..` 的路径，防止路径遍历攻击。

10. **Docker 非 root 用户**：多阶段构建中创建专用用户 `addgroup -S proverlap && adduser -S proverlap -G proverlap`，运行时 `USER proverlap`。

### 8.4 并发工程学习

11. **虚拟线程并行 LLM 调用**：Java 21 `Executors.newVirtualThreadPerTaskExecutor()`，每任务一个虚拟线程，I/O 阻塞时自动让出平台线程，适合 LLM 调用这种高延迟 I/O 场景。

12. **CompletableFuture 超时控制**：`f.get(timeoutSeconds, TimeUnit.SECONDS)` 为每个维度审查设置超时，超时返回降级结果。

---

## 九、YAML 摘要

```yaml
project: proverlap
type: "多模型交叉审查 GitHub Pull Request 自动化工具 (Spring Boot 服务)"
tech_stack:
  language: "Java 21"
  framework: "Spring Boot 4.0.6"
  llm: "LangChain4j 1.15 (OpenAI 兼容接口)"
  async: "CompletableFuture + 虚拟线程 (Java 21)"
  database: "PostgreSQL 16 + MyBatis-Plus 3.5.15"
  cache: "Redis 7"
  github: "自建轻量 REST 客户端 (RestClient + JWT RS256)"
  deploy: "Docker Compose (多阶段构建)"
  ci_cd: "GitHub Actions"
  code_style: "Spotless + google-java-format"
  test: "JUnit 5 + Mockito + Testcontainers"
lines_of_code:
  java_total: 4198
  java_main: 2855
  java_test: 1343
  python_cli: 98
  test_files: 8
scores:
  architecture: 5
  code_quality: 4
  test_coverage: 4
  security: 3
  maintainability: 4
  documentation: 5
  reproducibility: 4
  overall: 4.1
key_strengths:
  - "双模型交叉验证架构（共识=高置信/分歧=双视角标注）"
  - "维度×模型矩阵调度（PR 类型驱动维度选择）"
  - "三级 Tier 分级（diff 大小 + 敏感文件双维度）"
  - "三种审查阻塞模式（COMMENT_ONLY/BLOCK_UNTIL_REVIEWED/BLOCK_ON_FINDINGS）"
  - "GitHub App JWT 认证自实现（PKCS#1/PKCS#8 解析 + 令牌缓存 DCL）"
  - "虚拟线程并行 LLM 调用（Java 21）"
  - "HMAC 常量时间比较防时序攻击"
  - "路径遍历防护"
  - "8 个测试文件覆盖核心逻辑"
  - "Docker 多阶段构建 + 非 root 用户"
  - "CI/CD 版本化镜像推送至 GHCR"
  - "双入口设计（Webhook 异步 + API 同步）"
key_issues:
  - severity: P2
    issue: "POST /api/review 端点无鉴权或速率限制"
    location: "ReviewController.java 第 47-85 行"
  - severity: P2
    issue: "CrossValidationCommentFormatter 硬编码 DeepSeek/mimo 模型名"
    location: "CrossValidationCommentFormatter.java 第 32-33/37/45 行"
  - severity: P2
    issue: "CLI 脚本 verify=False 禁用 TLS 证书验证"
    location: "scripts/review.py 第 42 行"
  - severity: P2
    issue: "Redis 配置但代码中未使用"
    location: "docker-compose.yml 第 21-30 行 / application.yml 第 15-19 行"
  - severity: P2
    issue: "MyBatis-Plus 配置但 mapper/ 仅含 .gitkeep，无实际 Mapper"
    location: "mapper/.gitkeep"
  - severity: P2
    issue: "PostgreSQL 默认密码 proverlap"
    location: "docker-compose.yml 第 8 行"
  - severity: P3
    issue: "taskDimension 对所有 future 返回 unknown，超时日志丢失维度名"
    location: "ReviewOrchestrator.java 第 270 行"
  - severity: P3
    issue: "URI ref 参数字符串拼接未做 URL 编码"
    location: "GitHubClient.java 第 203 行"
  - severity: P3
    issue: "AGENTS.md 引用 PrReviewApplication.java，实际为 ProverlapApplication.java"
    location: "AGENTS.md 第 30 行"
  - severity: P3
    issue: "Testcontainers 依赖声明但无集成测试"
    location: "pom.xml 第 109-127 行"
reusability:
  - module: "双模型交叉验证算法"
    cost: low
  - module: "维度×模型矩阵调度"
    cost: low
  - module: "Tier 分级器"
    cost: low
  - module: "GitHub App JWT 认证"
    cost: medium
  - module: "令牌缓存 DCL 模式"
    cost: low
  - module: "HMAC 验签模式"
    cost: low
  - module: "上下文组装模式"
    cost: low
  - module: "Finding 去重算法"
    cost: low
  - module: "虚拟线程并行模式"
    cost: low
  - module: "Docker 多阶段构建"
    cost: low
  - module: "CI/CD 版本化镜像推送"
    cost: low
  - module: "PR 类型三层解析"
    cost: low
security_findings:
  - severity: P2
    type: "API 鉴权缺失"
    detail: "POST /api/review 无认证或速率限制"
    evidence_type: fact
  - severity: P2
    type: "TLS 验证禁用"
    detail: "scripts/review.py verify=False"
    evidence_type: fact
  - severity: P2
    type: "默认密码"
    detail: "docker-compose PostgreSQL 默认密码 proverlap"
    evidence_type: fact
  - severity: pass
    type: "HMAC 验签"
    detail: "MessageDigest.isEqual 常量时间比较防时序攻击"
    evidence_type: fact
  - severity: pass
    type: "路径遍历防护"
    detail: "extractFiles 过滤含 .. 的路径"
    evidence_type: fact
  - severity: pass
    type: "文件忽略"
    detail: ".gitignore 覆盖 .env/*.pem/*.key"
    evidence_type: fact
  - severity: pass
    type: "Docker 安全"
    detail: "非 root 用户运行"
    evidence_type: fact
  - severity: pass
    type: "密钥管理"
    detail: ".env.example 全部为占位符"
    evidence_type: fact
evidence_discipline:
  total_findings: 25
  fact: 23
  inference: 2
  hypothesis: 0
```
