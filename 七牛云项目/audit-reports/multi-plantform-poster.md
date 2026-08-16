# multi-plantform-poster (MPP) 项目审查报告

> 审查方法论：qiniu-project-audit（6 步：项目边界 → 产品回路 → 技术架构 → 工程质量评分 → 优缺点与复用矩阵 → 学习内容）
> 审查日期：2026-08-15
> 证据纪律：引用文件路径 + 行号；结论标注 fact / inference / hypothesis；先读高密度文件；不把文档目标当已实现

---

## 1. 项目边界

| 项 | 值 |
|---|---|
| 仓库路径 | `/Users/allure/Desktop/七牛云项目/multi-plantform-poster/` |
| 产品名 | MPP: multi-platform-poster |
| 许可证 | AGPL-3.0（fact，LICENSE + README badge） |
| 技术栈 | Go 1.26（backend + browser-worker + publish-worker）+ Python 3（ai-service, FastAPI + LangChain）+ Rust（content-pipeline-service, tonic gRPC）+ TypeScript（frontend Next.js + collab-service Fastify/Hocuspocus + extension WXT）+ PostgreSQL + Redis + Docker/Kubernetes |
| 模块数 | 6 个模块组：frontend / backend core / publishing pipeline / AI editing / remote browser session / data & infra（fact，`doc/module-design.md`） |
| Go LOC | ~44053 行（非测试，fact）+ ~28984 行测试 |
| Python LOC | ~2048 行（ai-service） |
| Rust LOC | ~5238 行（content-pipeline-service） |
| TS frontend LOC | ~30663 行 |
| TS collab LOC | ~3502 行 |
| TS extension LOC | ~9468 行 |
| 测试 | 后端 699 个 Go test 函数 / 102 文件；前端 40 个测试文件；collab 6 个；extension 12 个；Rust 67 个 test（fact） |
| Git 历史 | 仅 1 个 commit（`2c44cbd feat(publish): route publish workers by workspace (#371)`）（fact） |
| CI/CD | 5 个 GitHub workflows（ci / container-images / content-pipeline-integration / kubernetes-image-promotion / kubernetes-smoke）（fact） |
| 部署 | Docker Compose（dev + prod + TLS variants）+ Kubernetes（Kustomize, app-baseline / browser-runtime-control / observability / external-secrets / validation 包）（fact，`deploy/`） |
| Pre-commit | Lefthook：7 个模块各自的 format + lint（frontend/backend/browser-worker/ai-service/extension/collab-service/content-pipeline-service）（fact，`lefthook.yml`） |
| OpenAPI 契约 | `contracts/` 目录有 OpenAPI YAML + 代码生成脚本（generate.sh / generate-platform-capabilities.ts / bundle_openapi.rb），backend 用 oapi-codegen 生成 Go 类型（fact） |

**边界判定**：这是一个**生产级多语言微服务系统**，远超 demo 规模。它是面向创作者和运营团队的多平台内容发布工作台，核心是把一个源内容项目适配为各平台草稿、执行发布、跟踪状态、连接平台账号、AI 辅助编辑。技术复杂度和工程完整度是本批 5 个项目中最高的。

---

## 2. 用户与产品回路

### 目标用户（fact，README "creators and operations teams"）
- 内容创作者（需要一次写多处发）
- 运营团队（需要多账号管理 + 发布状态追踪 + 协同编辑）

### 核心产品回路
```
创建项目（源内容）→ 选平台 → 预发布适配（草稿格式转换）→ 审查/AI 编辑（proposal-confirmation）→ 连接账号（OAuth 或远程浏览器登录）→ 发布（队列 + 平台 adapter）→ 状态追踪 → 复盘
```

**五大创新层**（fact，README "Project Highlights" + `doc/module-design.md`）：

1. **平台草稿适配**：版本化 JSON draft contracts；微信收 HTML、知乎收 Markdown、X 收限长文本——预发布 adapter pipeline 解决格式不匹配，加平台不改编辑器核心。
2. **Adapter 平台隔离**：Go publisher + platform adapter 接口隔离第三方规则（账号模型/校验/API 风格/发布流程），不混入主业务。
3. **远程浏览器登录**：browser-worker 一次性 Chromium 会话 + CDP cookie 捕获 + Redis session token + PostgreSQL 审计——前端永不接触 raw cookies / CDP endpoints / browser state。
4. **可审查 AI 编辑**：独立 FastAPI AI service + 流式响应 + proposal-confirmation 工作流——AI 生成的编辑先预览/对比/接受，才更新草稿，不直接覆盖。
5. **VM 式无插件发布**：对无稳定公开 API 的平台（知乎/抖音），用后端控制的虚拟化浏览器运行时而非浏览器插件，草稿填写/媒体上传/发布动作在可审计的服务端流程里。

---

## 3. 技术架构

### 3.1 整体架构（6 模块组）

`doc/module-design.md` 定义了清晰的模块边界与跨模块规则（fact）：

```
Frontend Workspace（Next.js）
  ↕ dashboard API boundary
Backend Core（Go/Echo + GORM）
  ├── Publishing Pipeline（publisher factory + platform adapters + Asynq queue）
  ├── AI Editing（proxy → ai-service FastAPI/LangChain）
  ├── Remote Browser Session（browser-worker → Docker/K8s Chromium runtime）
  └── Data & Infra（PostgreSQL durable + Redis transient）
Collab Service（Fastify + Hocuspocus/Yjs，独立 WebSocket 服务）
Content Pipeline Service（Rust/tonic gRPC，草稿编译 + 媒体处理）
Extension（WXT，浏览器内容脚本本地发布）
```

跨模块规则（fact，`module-design.md` §8）：路由层只适配协议不持业务规则；domain services 持权限/状态转换/编排；平台差异在 adapter 后；稳定业务字段关系化、平台动态字段 JSON；AI 产出先审查再持久化；敏感状态不进前端；异步工作必须写持久最终状态；运行时容器短命可替换；Redis 锁/token 有 TTL 与归属校验。

### 3.2 Publisher 接口与平台 adapter

`backend/internal/publisher/core/publisher.go:11-14`（fact）定义核心接口：
```go
type PlatformPublisher interface {
    ValidateConfig(config []byte) error
    Publish(ctx context.Context, pub *models.ProjectPlatformPublication, account *models.PlatformAccount) (string, string, error)
}
```

`backend/internal/publisher/factory.go:90-125`（fact）：`Registry` 按 platform key 注册 publisher，`init()` 注册默认 4 平台（wechat/x/zhihu/douyin）。`Factory.GetPublisher(platform)` 路由。

**平台实现差异**（fact）：
- `wechat/wechat.go`：走微信公众号 API（UploadImage/UploadThumb/CreateDraft/Publish），需 AppID/AppSecret。
- `x/x.go`：走 OAuth2 + API，或 manual intent URL（`CreateXPostIntent`）。
- `zhihu/zhihu.go`：chromedp 浏览器自动化——Navigate write 页、填标题、填正文、上传图片、点发布（无公开 API，走 VM 式发布）。
- `douyin/douyin.go`：同理浏览器自动化 + cookie 校验。

这印证了 README 的「VM 式无插件发布」声明——是真实实现而非文档目标。

### 3.3 发布编排与队列

`backend/internal/services/publish/`（fact）：
- `service.go`：`Service` struct 持 db router / accounts / queue / browserWorkerClient / objectStorage / dashboardCache / readModels。`PublishProjectInWorkspaceWithContext`（line 403）是核心发布流程：校验 ownership → 查 publication → lifecycle.StartPublishAttempt → Factory.GetPublisher → ApplySavedCredentialsToPublication → preparePublicationMediaRefs → applySavedBrowserCookies（如需）→ lifecycle.MarkPublishing → resilience.Run(p.Publish) → lifecycle.CompletePublication → 记录 activity。
- `queue.go`：`PublishQueue` 接口（Enqueue/Start/AcquireLock/LockValue/RefreshLock/ReleaseLock）+ `RedisPublishQueue` 实现（Asynq）。锁用 Lua 脚本实现 owner-checked refresh/release（line 947-968），防误释放他人锁。幂等：`IdempotencyKey` + `findIdempotentPublishResponseForWorkspace` 查重放。
- 降级：`UseRedisQueue`/`UseRedisCoordination` 可选，Redis 不可用时 publish 可直连跑（module-design §3 "publishing can run directly when the queue is unavailable"）。

### 3.4 远程浏览器会话

`browser-worker/main.go`（fact）：Echo 服务，管理 browser runtime（Docker SDK 或 Kubernetes client），Redis 存 session state + TTL，30s 清理循环回收过期 session。`/ready` 检查 Redis ping。

`backend/internal/services/browser_session/service.go`（fact）：`BrowserSessionService` 管理会话生命周期——并发配额（user/tenant 级，env 可配）、stream token（5min TTL）、active session 去重、cleanup。会话状态机：pending → active → capturing → completed/cancelled/expired。

**安全边界**（fact，module-design §6）：前端永不收 raw cookies / CDP endpoints；后端持用户认证 + stream-token 校验 + 账号更新；worker 持容器与 CDP 细节；运行时容器一次性、不跨用户/平台共享 browser profile；cookie 持久化在专用 boundary 后，publisher 不依赖 raw storage shape。

### 3.5 AI 编辑服务

`ai-service/`（fact）：
- `main.py`：FastAPI app + lifespan ready flag + observability。
- `routes.py`：4 个端点——`/content/edit`（+stream）、`/prepublish/edit`（+stream）、`/calibrate`、`/growth/optimize/stream`。全部 `internal_auth`（bearer token，`secrets.compare_digest`）。流式用 `StreamingResponse`，先取 first chunk 再 yield（防空响应）。
- `llm_client.py`：`build_llm()` 返回 `ChatOpenAI`（OpenAI-compatible，`temperature=0`），env 配 provider_url/model/key/timeout/retries/cost。`response_usage` 算 token + cost。
- `prompts.py`：growth optimization 有平台 audience profiles（wechat/zhihu/x/douyin 各有 profile_id/audience_summary/ranking_signals/content_guidance/title_strategy/body_strategy/comparison_strategy/engagement_strategy/risk_warnings）。
- **确定性质量检查覆盖 LLM**（fact，`routes.py:460-501`）：`apply_growth_quality_checks` 用确定性 checks（brand_consistency/banned_words/length/cta/risk_statements）覆盖 LLM 产出的同 key checks——"Deterministic checks take precedence over model-provided checks so the LLM cannot bypass quality gates"。这是「确定性引擎守全局状态」范式在内容质量领域的应用。
- **fallback**（fact，`routes.py:631-684`）：LLM 解析失败时 `fallback_growth_proposals` 产出占位 proposal，标 warning。

### 3.6 Content Pipeline（Rust）

`content-pipeline-service/`（fact）：
- gRPC 服务（tonic），两个 server：`PlatformDraftCompiler` + `MediaAssetProcessor`。
- `content-pipeline-core/src/drafts.rs`：`DraftCompiler.compile(source_project, draft_target) → DraftOutput`。源格式只支持 HTML，按平台 + profile 生成 adapted_content（wechat=html / zhihu=markdown / x=text / ...）。`DraftCompileError` 枚举显式错误（EmptySource/UnsupportedSourceFormat/UnsupportedPlatform/UnsupportedProfile/Encode/SchemaValidation）。
- 媒体处理：image/oxipng/mozjpeg/webp 优化 + resize/conversion/lossless/perceptual 优化器。
- health check + reflection + metrics（Axum）。

这是「确定性内容转换在类型化服务边界后」的落地——用 Rust 的强数据建模 + 显式错误处理做草稿编译。

### 3.7 协同编辑（collab-service）

`collab-service/src/collab/hocuspocus.ts`（fact）：Hocuspocus server，`onConnect`/`onAuthenticate` 校验 session token（jose 签名，由 backend 签发）+ role（editor/viewer，viewer readOnly）。`onLoadDocument`/`onChange`/`onStoreDocument` 接 PostgreSQL 持久化 + Redis pub-sub 多副本同步。metrics 暴露 activeConnections/authDenials/activeDocuments。

与 backend 分离的设计（fact，tech-stack.md）：backend 签发 session + 强制 access rules，但不 host CRDT WebSocket server——collab-service 独立处理 Yjs 文档同步。

### 3.8 数据层与基础设施

- **PostgreSQL**：durable source of truth（users/projects/publications/accounts/browser session audit）。GORM + datatypes.JSON for platform-specific dynamic fields。
- **Redis**：transient coordination（Asynq publish queue + locks + OAuth state + browser session state + stream tokens + collab pub-sub）。全有 TTL。
- **DB Router**（fact，`backend/internal/db/router.go`）：writer/reader 分离，strongRead 一致性读，sticky_writer 中间件，replica_lag 监控，monthly/hash_partitions 归档。
- **Object Storage**：S3/R2-compatible（`backend/internal/pkg/objectstorage/`），fake client for test。
- **Observability**：Prometheus + Grafana + Loki + Alloy（K8s 部署有 podmonitors/alerts/networkpolicy）。

### 3.9 前端与扩展

- **Frontend**（Next.js App Shell）：TipTap 富文本编辑 + Yjs 协同 + react-diff-view 审查 AI proposal + Zustand 本地状态 + shadcn UI + i18n + SEO（robots/sitemap/opengraph）。
- **Extension**（WXT）：background + side panel + trust-origin page + content scripts（zhihu/x/douyin/xiaohongshu/bilibili）。content script 注册 adapter runner，各平台有独立 adapter。extension 是 server-side publishing 的补充（用户浏览器上下文/content-script 自动化场景）。

---

## 4. 工程质量评分（11 维，1-5）

| 维度 | 分 | 依据 |
|---|---|---|
| 架构合理性 | 5 | 6 模块组边界清晰，跨模块规则显式；publisher 接口 + factory 隔离平台；AI proposal-confirmation 防覆盖；remote browser 安全边界严格；确定性 content pipeline 独立服务；collab 与 backend 分离（fact，module-design + 源码验证） |
| 代码质量 | 5 | Go 类型化 service boundary + interface 注入 + 可 mock；Python Pydantic schema + LangChain provider boundary；Rust 强类型 + 显式 error enum；TS 类型安全 + catalog 统一版本；Lua 脚本 owner-checked lock；SanitizeUserFacingErrorMessage 脱敏（fact） |
| 测试覆盖 | 4 | 后端 699 test / 102 文件（覆盖 publish/browser_session/dashboard/collab/middleware/db）；前端 40 文件；collab 6；extension 12；Rust 67 test。但无集成/E2E 跨服务测试证据、无覆盖率阈值（fact） |
| 可维护性 | 4 | 模块化彻底、契约驱动（OpenAPI codegen）、catalog 统一依赖版本、lefthook 多语言 pre-commit；但单 commit 历史无法追溯演进、多语言 monorepo 认知负担高（fact + inference） |
| 可扩展性 | 5 | 「加平台 = 定义 platform key + draft format + validation rules + publisher adapter」（module-design §4）；publisher Registry init() 注册；extension content script 注册 adapter runner；platform capabilities 生成代码；加 AI action 定义 input/output/prompt/review（fact） |
| 性能优化 | 4 | writer/reader 分离 + strongRead；sticky writer；read model 异步刷新；collab debounce flush；Redis 锁 TTL + refresh；Asynq 并发 2 + retry 3；但部分 chromedp 用 Sleep(5s) 硬等（fact，zhihu.go） |
| 安全性 | 5 | 前端不接触 raw cookies/CDP；internal bearer token（secrets.compare_digest）；cookie encryption key；stream token TTL；user/tenant 并发配额；sensitive error query param 脱敏正则；jose 签名 collab session；OAuth state Redis store；banned words 检查；RLS-style access policy（fact，browser_session/publish/middleware/accesspolicy） |
| 错误处理 | 4 | DraftCompileError 显式枚举；publish lifecycle failAttempt 闭环；幂等重放；AI fallback proposals；resilience.Run 重试；Lua lock 防误释放；AI stream first-chunk 空检测；但 chromedp 浏览器自动化的脆弱性（平台 DOM 变动即坏）是固有风险（fact + inference） |
| 文档质量 | 5 | README + module-design.md + tech-stack.md + module-interface.md + new-platform-development-guide.md + setup(3 种)/setup-dev/setup-standalone/setup-kubernetes/kubernetes-operations-runbook/openAPI-code-generation-guide/node-dependency-management/platform/remote_browser_session——文档体系极完整（fact） |
| 部署运维 | 5 | Docker Compose（dev/prod/TLS manual/TLS letsencrypt）+ Kubernetes（Kustomize: app-baseline/browser-runtime-control/observability/external-secrets/validation）+ 5 CI workflows + Lefthook + Air hot-reload + Prometheus/Grafana/Loki/Alloy——本批项目中部署运维最完整（fact） |
| 依赖管理 | 5 | pnpm catalog + overrides 统一 TS 版本；uv.lock（Python）；go.sum（Go）；Cargo.lock（Rust）；pnpm-lock.yaml；lefthook 多语言格式化——全模块 lock 文件齐全（fact） |

**综合工程分：5**（全维度高分，是本批项目中工程成熟度最高的。唯一系统性风险是浏览器自动化的平台 DOM 依赖与单 commit 历史）

---

## 5. 优缺点与复用矩阵

### 优点
1. **契约驱动的多语言微服务**：OpenAPI YAML → oapi-codegen Go 类型 + 前端 generated 类型 + platform-capabilities.json 生成代码——跨语言契约对齐，是大型多语言项目的基石（fact）。
2. **Publisher 接口 + Registry factory**：`PlatformPublisher` 接口 + `init()` 注册——加平台不改主流程，平台差异完全隔离。这是「adapter 模式 + 注册表」的标准教科书实现（fact）。
3. **远程浏览器会话的安全边界**：前端永不接触 raw cookies/CDP，stream token TTL，user/tenant 并发配额，一次性容器不跨用户共享 profile——把高风险的浏览器自动化关在严格边界后（fact）。
4. **AI proposal-confirmation 工作流 + 确定性质量检查覆盖 LLM**：AI 产出先审查再持久化，确定性 checks 覆盖 LLM checks——防 AI 绕过质量门（fact，routes.py:460-501）。
5. **Redis 锁的 owner-checked Lua 脚本**：refresh/release 用 Lua 校验 value 防误释放他人锁——分布式锁的正确实现（fact，queue.go:947-968）。
6. **发布幂等 + 重放**：IdempotencyKey + findIdempotentPublishResponseForWorkspace + waitForIdempotentPublishResponseForWorkspace——防重复发布与重放（fact，service.go:652-750）。
7. **collab 与 backend 分离**：backend 签 session + 强制 access rules，collab-service 独立 host CRDT WebSocket——职责分离，可独立扩展（fact）。
8. **部署体系完整**：Docker Compose 多 variant + Kubernetes Kustomize 多包 + CI/CD + observability + external-secrets——生产级 DevOps（fact）。

### 缺点 / 风险
1. **单 commit 历史**：PR #371 是唯一 commit，6 个模块组、12 万+ 行代码的演进过程完全不可追溯——审查无法验证任何设计决策的发生时序（fact）。
2. **浏览器自动化的平台 DOM 依赖**：zhihu/douyin publisher 用 chromedp 操作具体 CSS selector（`textarea[placeholder*="标题"]`）+ `Sleep(5s)` 硬等——平台改版即坏，是脆弱的固有风险（fact，zhihu.go）。
3. **多语言 monorepo 认知负担**：Go + Python + Rust + TS 四语言、6+ 服务、pnpm catalog + uv + go mod + cargo 四套依赖管理——维护需全栈能力（inference）。
4. **Rust content-pipeline 的必要性存疑**：草稿编译（HTML→text/markdown）与媒体优化用 Rust 是性能/类型安全优势，但对一个内容发布系统是否过度工程值得讨论——核心复杂度在发布编排与浏览器自动化，不在草稿编译（hypothesis）。
5. **AGPL-3.0 许可证**：对商业采用有传染性要求，可能限制部分企业用户（fact）。
6. **无跨服务集成测试证据**：各模块有单元测试，但未见跨服务端到端测试——6 个服务的集成正确性靠 CI workflow 间接验证（inference）。

### 复用矩阵

| 资产 | 复用价值 | 复用条件 | 不可复用部分 |
|---|---|---|---|
| Publisher 接口 + Registry factory（`publisher/core`+`factory.go`） | 高 | 任何多平台发布/集成的 Go 项目 | 无 |
| Redis owner-checked Lua 锁（`queue.go`） | 高 | 任何 Redis 分布式锁场景 | 无 |
| 发布幂等 + 重放模式（`service.go`） | 高 | 任何异步任务去重/重放 | 绑 GORM 模型 |
| 远程浏览器会话安全边界设计（`browser_session/`+`browser-worker`） | 高 | 任何需要浏览器自动化的 SaaS（RPA/爬虫/登录代理） | 绑 Docker/K8s runtime |
| AI proposal-confirmation + 确定性 checks 覆盖 LLM（`ai-service/routes.py`） | 高 | 任何 AI 辅助编辑/审核系统 | 绑 LangChain/OpenAI-compatible |
| OpenAPI 契约 → 多语言 codegen 流程（`contracts/`） | 高 | 任何多语言微服务 | 绑 oapi-codegen 工具链 |
| Draft compiler 模式（`content-pipeline-core/drafts.rs`） | 中 | 任何多格式内容转换 | Rust 选择可换 |
| Hocuspocus collab 分离设计（`collab-service/`） | 中 | 任何需要实时协同编辑的 SaaS | 绑 TipTap/Yjs 生态 |
| 平台 audience profiles + growth optimization prompt 模式（`prompts.py`） | 中 | 任何多平台内容增长优化 | profile 文本本身 |
| DB Router writer/reader 分离 + sticky writer（`db/`） | 中 | 任何读写分离的 PostgreSQL 应用 | 绑 GORM |
| WXT extension adapter runner 模式（`extension/`） | 中 | 任何多站点浏览器扩展自动化 | 绑 WXT |
| Kubernetes Kustomize 多包结构（`deploy/kubernetes/`） | 高 | 任何 K8s 多服务部署 | 绑具体服务 |

---

## 6. 学习内容

### 6.1 可直接学习的工程模式
1. **契约驱动多语言微服务**：OpenAPI YAML 为 single source of truth → codegen 各语言类型——跨语言协作的标准答案。
2. **Publisher 接口 + Registry factory + init() 注册**：把「加平台不改主流程」落到代码——adapter + registry 的教科书实现。
3. **远程浏览器会话的安全分层**：前端 → backend（认证/token/账号更新）→ worker（容器/CDP）→ runtime（一次性容器）——高风险浏览器自动化的安全架构模板。
4. **AI proposal-confirmation + 确定性 checks 覆盖 LLM**：AI 产出先审查再持久化 + 确定性质量门不可被 LLM 绕过——AI 辅助系统的安全范式。
5. **Redis owner-checked Lua 锁**：refresh/release 用 Lua 校验 value——分布式锁的正确实现，防误释放。
6. **发布幂等 + 重放**：IdempotencyKey + 查重放 + 等重放——异步任务去重的完整模式。
7. **collab 与 backend 分离**：业务 API 签 session + 强制 access，协同服务独立 host CRDT WS——实时协同 SaaS 的职责分离。
8. **Kustomize 多包 K8s 部署**：app-baseline / browser-runtime-control / observability / external-secrets / validation 分包——复杂多服务 K8s 部署的组织方式。

### 6.2 可反思的教训
1. **单 commit 历史是审查的最大障碍**：12 万行代码、6 模块、PR #371 一个 commit——所有架构演进、设计取舍、bug 修复时序全丢失。Git 历史是大型项目审查的基础设施，squash-merge 到单 commit 让项目变成黑盒。
2. **浏览器自动化的脆弱性**：chromedp 操作具体 CSS selector + Sleep 硬等——平台改版即坏，是「无插件 VM 发布」创新的核心代价。应考虑更稳健的 selector 策略或平台 API 优先。
3. **多语言选择的权衡**：Rust 做 content-pipeline 的类型安全与性能优势真实，但对内容发布系统是否必要值得讨论——过度工程与正确投资的边界需结合团队语言能力判断。
4. **跨服务集成测试的缺口**：单元测试充分但跨服务 E2E 未见——6 服务的集成正确性风险随服务数增长。

### 6.3 与同批项目的横向对比
- **与 oral 对比**：oral 是单用户 demo、单语言（Python）、单 commit；MPP 是生产级多语言微服务、单 commit。两者都因单 commit 丢失演进证据，但 MPP 的复杂度让这个损失更严重。
- **与 EnglishPartner 对比**：EnglishPartner 用 Provider 可替换 + fallback 换健壮性；MPP 用 publisher 接口 + factory + 确定性 checks 覆盖 LLM 换可扩展性与质量门——两者都用接口隔离外部依赖，MPP 的规模更大。
- **与 PlotPulse 对比**：PlotPulse 的「LLM as part, 确定性引擎守全局状态」在 MPP 的 AI service 确定性质量检查覆盖 LLM 中有回响——确定性优先是跨项目的共同信念。
- **本批最高工程成熟度**：MPP 在部署运维、契约驱动、安全边界、多语言管理上都是 5 个项目中最完整的，是生产级系统的范本。

---

## 审查结论

multi-plantform-poster 是本批 5 个项目中**工程成熟度最高、技术复杂度最大**的项目。它是一个生产级多语言微服务系统，6 模块组边界清晰、契约驱动、安全边界严格、部署体系完整。五大创新层（草稿适配/平台隔离/远程浏览器登录/可审查 AI 编辑/VM 式发布）都有真实代码落地，不是文档目标。publisher 接口 + registry factory、Redis owner-checked Lua 锁、AI proposal-confirmation + 确定性 checks 覆盖、OpenAPI 契约 codegen、Kustomize 多包 K8s 部署都是可复用到其他生产系统的高价值资产。主要风险是单 commit 历史让演进不可追溯、浏览器自动化对平台 DOM 的脆弱依赖、多语言 monorepo 的认知负担。这是一个可以作为多语言微服务架构教学样例的项目。

---

```yaml
project: multi-plantform-poster
one_line_judgment: 本批工程成熟度最高的生产级多语言微服务系统，6 模块组边界清晰+契约驱动+安全边界严格+部署完整，五大创新层均有真实代码落地
product_type: 多平台内容发布工作台（创作者/运营团队 SaaS）
target_users: 内容创作者 + 运营团队（多账号管理、多平台发布、协同编辑）
core_loop: 创建项目源内容 → 选平台预发布适配 → 审查/AI 编辑（proposal-confirmation）→ 连接账号（OAuth/远程浏览器）→ 队列发布（平台 adapter）→ 状态追踪复盘
architecture_style: 契约驱动多语言微服务（OpenAPI codegen）+ Publisher 接口+Registry factory 平台隔离 + Redis Asynq 队列+owner-checked Lua 锁 + 远程浏览器会话安全分层 + AI proposal-confirmation+确定性 checks 覆盖 + collab 与 backend 分离（Hocuspocus/Yjs）+ Rust gRPC content pipeline + Docker/K8s 部署
stack: [Go 1.26, Echo, GORM, PostgreSQL, Redis, Asynq, chromedp, Next.js, React 19, TypeScript, TipTap, Yjs, Hocuspocus, Fastify, FastAPI, Python, LangChain, Rust, tonic, gRPC, WXT, Docker, Kubernetes, Kustomize, Traefik, Prometheus, Grafana, Loki]
strongest_patterns:
  - 契约驱动多语言微服务（OpenAPI YAML → oapi-codegen Go + 前端 generated + platform-capabilities 生成）
  - Publisher 接口 + Registry factory + init() 注册（加平台不改主流程）
  - 远程浏览器会话安全分层（前端不接触 raw cookies/CDP，stream token TTL，user/tenant 配额，一次性容器）
  - AI proposal-confirmation + 确定性 checks 覆盖 LLM（防 AI 绕过质量门）
  - Redis owner-checked Lua 锁（refresh/release 校验 value 防误释放）
  - 发布幂等 + 重放（IdempotencyKey + 查重放 + 等重放）
  - collab 与 backend 分离（backend 签 session+强制 access，collab 独立 host CRDT WS）
  - Kustomize 多包 K8s 部署（app-baseline/browser-runtime-control/observability/external-secrets/validation）
main_risks:
  - 单 commit 历史 12 万行代码演进不可追溯
  - 浏览器自动化对平台 DOM 的脆弱依赖（chromedp selector + Sleep 硬等，平台改版即坏）
  - 多语言 monorepo 认知负担（Go+Python+Rust+TS 四语言六服务）
  - Rust content-pipeline 的必要性存疑（可能过度工程）
  - AGPL-3.0 许可证传染性限制商业采用
  - 无跨服务集成测试证据
business_scenarios:
  - 多平台内容一次编写多处发布（微信/知乎/X/抖音）
  - 多账号管理 + OAuth/远程浏览器登录
  - AI 辅助内容编辑与增长优化（proposal-confirmation）
  - 实时协同编辑（多用户同文档）
  - 无公开 API 平台的 VM 式浏览器发布
reusable_assets:
  - backend/internal/publisher/core + factory.go（Publisher 接口+Registry factory）
  - backend/internal/services/publish/queue.go（Redis owner-checked Lua 锁）
  - backend/internal/services/publish/service.go（发布幂等+重放模式）
  - backend/internal/services/browser_session/（远程浏览器会话安全边界设计）
  - ai-service/routes.py（AI proposal-confirmation+确定性 checks 覆盖 LLM）
  - contracts/（OpenAPI 契约→多语言 codegen 流程）
  - content-pipeline-service/crates/content-pipeline-core/src/drafts.rs（Draft compiler 模式）
  - collab-service/src/collab/hocuspocus.ts（Hocuspocus collab 分离设计）
  - deploy/kubernetes/（Kustomize 多包 K8s 部署结构）
  - backend/internal/db/（DB Router writer/reader 分离+sticky writer）
  - ai-service/prompts.py（平台 audience profiles+growth optimization prompt 模式）
  - extension/entrypoints/（WXT extension adapter runner 模式）
non_reusable_parts:
  - 各平台 chromedp selector 与 Sleep 硬等（绑具体平台 DOM）
  - wechat/x 的 API client（绑具体平台 API）
  - 各模块的业务模型（GORM models / Pydantic schemas / Rust structs）
  - AGPL-3.0 许可证约束
  - 具体 K8s 部署的服务名/端口/配置
scores:
  product: 5
  architecture: 5
  engineering: 5
  reuse: 5
  commercialization: 4
evidence:
  - path: doc/module-design.md
    lines: 全文
    note: 6 模块组设计+跨模块规则（路由层不持业务规则/平台差异在 adapter 后/AI 先审查再持久化/敏感状态不进前端/异步工作写持久最终状态）
    type: fact
  - path: doc/tech-stack.md
    lines: 全文
    note: 各模块技术选型理由+问题解决映射
    type: fact
  - path: backend/internal/publisher/core/publisher.go
    lines: 11-14
    note: PlatformPublisher 接口定义（ValidateConfig+Publish）
    type: fact
  - path: backend/internal/publisher/factory.go
    lines: 90-125
    note: Registry 注册 4 平台 publisher，Factory.GetPublisher 路由
    type: fact
  - path: backend/internal/publisher/platforms/zhihu/zhihu.go
    lines: 1-60
    note: chromedp 浏览器自动化发布（Navigate/填标题/Sleep 5s），印证 VM 式无插件发布
    type: fact
  - path: backend/internal/publisher/platforms/wechat/wechat.go
    lines: 1-50
    note: 微信公众号 API 发布（UploadImage/CreateDraft/Publish），API 式平台
    type: fact
  - path: backend/internal/services/publish/service.go
    lines: 403-550
    note: PublishProjectInWorkspaceWithContext 核心发布流程（ownership 校验→lifecycle→Factory.GetPublisher→ApplySavedCredentials→MarkPublishing→resilience.Run(Publish)→CompletePublication）
    type: fact
  - path: backend/internal/services/publish/service.go
    lines: 652-750
    note: 发布幂等+重放（IdempotencyKey+findIdempotentPublishResponseForWorkspace+waitForIdempotentPublishResponseForWorkspace）
    type: fact
  - path: backend/internal/services/publish/queue.go
    lines: 947-968
    note: Redis owner-checked Lua 锁（refresh/release 校验 value 防误释放）
    type: fact
  - path: backend/internal/services/publish/queue.go
    lines: 797-811
    note: Asynq 队列常量（MaxRetry 3/Timeout 30min/LockTTL 30min/Concurrency 2）
    type: fact
  - path: backend/internal/services/browser_session/service.go
    lines: 1-60
    note: BrowserSessionService 错误枚举+常量（TTL/concurrency quota/stream token TTL/Redis key prefix）
    type: fact
  - path: browser-worker/main.go
    lines: 67-90
    note: browser-worker Echo 服务（runtime manager+Redis state store+session manager+30s 清理循环）
    type: fact
  - path: ai-service/routes.py
    lines: 170-186
    note: internal_auth bearer token（secrets.compare_digest）
    type: fact
  - path: ai-service/routes.py
    lines: 460-501
    note: apply_growth_quality_checks 确定性 checks 覆盖 LLM checks（brand_consistency/banned_words/length/cta/risk_statements）
    type: fact
  - path: ai-service/routes.py
    lines: 631-684
    note: fallback_growth_proposals（LLM 解析失败时占位 proposal+warning）
    type: fact
  - path: ai-service/llm_client.py
    lines: 812-844
    note: build_llm 返回 ChatOpenAI（temperature=0/streaming/timeout/retries/cost 配置）
    type: fact
  - path: ai-service/prompts.py
    lines: 970-1040
    note: growth optimization 平台 audience profiles（wechat/zhihu/x/douyin 各有完整策略字段）
    type: fact
  - path: content-pipeline-service/crates/content-pipeline-core/src/drafts.rs
    lines: 1-100
    note: DraftCompiler.compile 源 HTML→平台 adapted_content，DraftCompileError 显式枚举
    type: fact
  - path: content-pipeline-service/crates/content-pipeline-service/src/main.rs
    lines: 1-60
    note: tonic gRPC 服务（PlatformDraftCompiler+MediaAssetProcessor+health+reflection）
    type: fact
  - path: collab-service/src/collab/hocuspocus.ts
    lines: 1-100
    note: Hocuspocus server（onConnect/onAuthenticate 校验 session token+role，onLoadDocument/onChange/onStoreDocument 接 PostgreSQL+Redis pub-sub）
    type: fact
  - path: contracts/
    note: OpenAPI YAML+codegen 脚本（generate.sh/generate-platform-capabilities.ts/bundle_openapi.rb），backend oapi-codegen 生成 Go 类型
    type: fact
  - path: lefthook.yml
    note: 7 模块 pre-commit format+lint（frontend/backend/browser-worker/ai-service/extension/collab-service/content-pipeline-service）
    type: fact
  - path: deploy/kubernetes/
    note: Kustomize 多包（app-baseline/browser-runtime-control/observability/external-secrets/validation）
    type: fact
  - path: .github/workflows/
    note: 5 CI workflows（ci/container-images/content-pipeline-integration/kubernetes-image-promotion/kubernetes-smoke）
    type: fact
  - path: backend/internal/db/router.go
    note: DB Router writer/reader 分离+strongRead+sticky_writer
    type: fact
  - path: backend/internal/services/publish/service.go
    lines: 366-368
    note: SanitizeUserFacingErrorMessage 脱敏（secret/access_token/x-amz-* query param 正则替换）
    type: fact
  - path: git log
    note: 仅 1 commit（2c44cbd feat(publish): route publish workers by workspace (#371)），12 万行演进不可追溯
    type: fact
  - note: Rust content-pipeline 对内容发布系统的必要性存疑（核心复杂度在发布编排与浏览器自动化，不在草稿编译）
    type: hypothesis
  - note: 多语言 monorepo 认知负担高（Go+Python+Rust+TS 四语言六服务）
    type: inference
  - note: 无跨服务集成测试证据（各模块单元测试充分但 E2E 未见）
    type: inference
confidence: high
```
