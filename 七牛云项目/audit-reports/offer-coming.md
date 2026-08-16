# offer-coming 项目审查报告

## 一句话判断

一个面向"小说转剧本"长文本 AI 生成场景的 Java 多模块工程，DDD 分层清晰、任务编排与 MQ 重试机制扎实，但 prompt 硬编码、错误分类粗糙、并发与一致性缺乏事务/锁保护，属于"架构完整、工程可落地、细节待打磨"的准生产级作品（合理推断）。

---

## 项目地图

- **项目根目录**：`/Users/allure/Desktop/七牛云项目/offer-coming/`
- **类型**：Java 21 + Spring Boot 3.2.5 多模块 Maven 工程 + Vue3 前端 + RabbitMQ 异步 Worker
- **规模**：323 个 Java 文件，8 个后端 Maven 模块，约 40 个 Vue 视图
- **目录结构**（事实）：
  - `offer-code/` —— 后端多模块
    - `offer-common/` —— 工具类、枚举、异常、MQ 消息、result 封装
    - `offer-domain/` —— 领域模型与 Repository 接口（task/novel/chunk/script/profile/quota/payment/user 等）
    - `offer-application/` —— 应用服务层（admin/auth/novel/notification/payment/profile/task 7 个业务包）
    - `offer-infra/` —— 基础设施（MyBatis-Plus 持久化、MinIO、RabbitMQ、文本预处理、安全）
    - `offer-server/` —— Web 入口（Controller、Security、DTO、Application 启动类）
    - `offer-worker/` —— 异步任务消费者（TaskCreateMessageListener、DeepseekChunkProcessor）
    - `db/offer-coming-sql.sql` —— 517 行建表脚本（517 行）
  - `offer-web/` —— Vue3 + Pinia + Element Plus + Monaco Editor 前端
  - `deploy/` —— docker-compose、nginx、systemd 部署配置
  - `docs/` —— 8 份设计文档（架构、数据库、需求、部署、YAML Schema 等）
- **技术栈**（事实，来源 `offer-code/pom.xml:24-38`）：
  - Java 21、Spring Boot 3.2.5、Spring Cloud 2023.0.1、MyBatis-Plus 3.5.6、Spring AI 1.0.0-M6
  - MinIO 8.5.7、Hutool 5.8.26、JJWT 0.12.5、BCrypt 3.5.6、SnakeYAML 2.2
  - MySQL 8+、Redis、RabbitMQ 3+、MinIO
  - 前端：Vue3、Vite、Pinia、Element Plus、Monaco Editor、axios

---

## 产品与业务场景

- **产品形态**（事实，来源 `README.md:11-13`）：面向小说改编场景的智能化系统，将 `.txt` 小说转换为结构化剧本初稿，并提供任务管理、在线编辑、导出和后台治理能力。
- **目标用户**（合理推断）：需要进行小说改编的编剧、内容创作者、影视行业从业者；README 自述定位为"毕业设计项目展示 / AI 应用课程答辩 / 内容创作辅助工具原型"（`README.md:300-304`，事实）。
- **核心业务循环**（事实，来源 `README.md:264-272`）：
  1. 用户上传 TXT 小说 → 系统章节预处理
  2. 用户创建转换任务 → 后端投递任务消息到 RabbitMQ
  3. Worker 消费任务并调用 AI 接口生成结构化剧本
  4. 用户在线查看、编辑和导出剧本
- **业务能力**（事实，来源 README + 代码）：
  - 用户端：注册登录（手机号+短信验证码+图形验证码）、额度管理、小说上传、章节预处理、任务创建/取消/暂停/恢复/重试、剧本在线编辑（Monaco YAML）、故事档案、通知
  - 管理端：用户管理、任务监控、Prompt 模板管理、系统配置、操作日志、Dashboard 概览
  - 支付：充值套餐、模拟支付（mockPay，`PaymentApplicationService.java:95`，事实）

---

## 架构分解

### 分层架构（事实）

采用标准的 DDD 四层 + 两个入口模块：

| 层 | 模块 | 职责 | 证据 |
|---|---|---|---|
| Common | offer-common | 工具类、枚举、异常、统一 Result、MQ 消息 | `offer-common/src/main/java/com/offer/common/result/Result.java` |
| Domain | offer-domain | 领域模型 + Repository 接口（纯接口，无实现） | `offer-domain/.../task/repository/TaskRepository.java` 等接口 |
| Application | offer-application | 应用服务编排（命令/DTO/服务），依赖 Domain 接口 | `offer-application/.../task/service/TaskApplicationService.java` |
| Infrastructure | offer-infra | Repository 实现、MinIO、RabbitMQ、文本预处理、安全 | `offer-infra/.../persistence/repository/task/TaskRepositoryImpl.java` |
| Server | offer-server | Web Controller、Spring Security、JWT 过滤器、DTO | `offer-server/.../security/SecurityConfig.java` |
| Worker | offer-worker | RabbitMQ 消费者、Spring AI 调用、chunk 处理 | `offer-worker/.../task/consumer/TaskCreateMessageListener.java` |

**依赖方向**（合理推断）：Domain 不依赖任何层；Application 依赖 Domain；Infra 依赖 Domain + Application（实现接口）；Server/Worker 依赖 Application + Infra。这是教科书式的 DDD 落地（合理推断）。

### 关键架构模式

**1. 任务编排 + MQ 异步处理（核心模式）**
- `TaskApplicationService.createTask`（`offer-application/.../task/service/TaskApplicationService.java:54-122`）创建任务 + chunk 记录后，通过 `TaskMessagePublisher` 发布消息
- `TaskCreateMessageListener`（`offer-worker/.../task/consumer/TaskCreateMessageListener.java:29-50`）消费消息
- `TaskCreateWorkerService.handle`（`offer-worker/.../task/service/TaskCreateWorkerService.java:28-58`）逐 chunk 调用 `DeepseekChunkProcessor.process`
- 每个 chunk 完成后调用 `TaskExecutionApplicationService.finalizeChunk` 更新状态并触发剧本聚合（`offer-application/.../task/service/TaskExecutionApplicationService.java:218-272`）

**2. RabbitMQ 死信队列 + 手动重试**（事实，`offer-infra/.../mq/config/TaskMqConfig.java` + `TaskCreateMessageListener.java:52-98`）
- 配置了 `taskExchange` + `taskDeadLetterExchange` + `taskCreateQueue`（带 `x-dead-letter-exchange` 参数）+ `taskCreateDeadLetterQueue`
- 消费失败时通过 `x-retry-count` header 计数，达到 `MAX_REQUEUE_ATTEMPTS=3` 后 `basicReject` 进死信队列，并标记任务失败
- 这是合理的重试与死信处理模式（合理推断）

**3. Chunk 分片 + 章节树感知切分**（事实，`TaskApplicationService.java:355-508`）
- `splitText` 优先按 `chapterTree`（JSON）中的 `chapterIndex/startIndex/endIndex` 切分
- 对 `chapterTree` 做严格校验：`hasAnyContentNode`、`hasInvalidBoundary`、`hasInvalidSliceOrdering`（`TaskApplicationService.java:376-398`）
- 无章节树时 fallback 到固定 2000 字符切分（`splitByFixedLength`，`TaskApplicationService.java:500-508`）
- 每个 chunk 生成 `sourceTextHash`（SHA256）用于幂等校验（`TaskApplicationService.java:107`）

**4. 额度预扣 + 退还 + 日志**（事实，`QuotaApplicationService.java`）
- 创建任务时 `assertAndDeductQuota` 预扣预估 Token（`QuotaApplicationService.java:37-60`）
- 取消任务时 `refundQuota` 退还（`TaskApplicationService.java:212`）
- 每次变更写 `QuotaLog` 记录 balanceBefore/balanceAfter（`QuotaApplicationService.java:151-165`）
- 额度低于阈值时自动发送通知（`QuotaApplicationService.java:122-148`）

**5. LLM 结果校验 + 重试 + 聚合**（事实）
- `DeepseekChunkProcessor.process`（`offer-worker/.../task/service/DeepseekChunkProcessor.java:48-91`）调用 LLM 后，`parseAndValidateResult` 做 14 条结构校验
- 校验失败（`JSON_SCHEMA_INVALID`）时用 `buildRetryPrompt` 重新调用一次（`DeepseekChunkProcessor.java:56-70`）
- JSON 提取支持 markdown fence 和裸 JSON 对象两种模式，并有手写括号匹配解析器（`DeepseekChunkProcessor.java:418-453`）
- `ScriptAggregator.aggregate`（`offer-application/.../task/service/ScriptAggregator.java:45-111`）将所有成功 chunk 的 acts/scenes 合并为统一剧本，重新编号 actNumber/sceneNumber

**6. JWT + Spring Security 无状态认证**（事实，`offer-server/.../security/SecurityConfig.java` + `JwtAuthenticationFilter.java`）
- `SessionCreationPolicy.STATELESS` + `JwtAuthenticationFilter`
- 公开端点白名单：注册/登录/刷新/验证码/短信/重置密码（`SecurityConfig.java:34-42`）
- `JwtAuthenticationFilter` 校验 token 后从 DB 加载 User，检查 DISABLED/LOCKED 状态，设置 `AuthenticationContext`（ThreadLocal）

---

## 工程评分（1-5，附证据）

| 维度 | 分数 | 证据与判断 |
|---|---|---|
| **架构合理性** | 4 | DDD 四层 + 双入口（server/worker）+ MQ 解耦，依赖方向正确（事实）。扣分：Domain 模型是贫血 POJO（`Task.java`、`Novel.java` 全是 getter/setter，`Novel.java` 有少量行为方法），缺乏聚合根与领域服务（合理推断） |
| **代码质量** | 4 | 命名规范、包结构清晰、Lombok 减少样板、`@RequiredArgsConstructor` 构造注入（事实）。扣分：部分类过长（`DeepseekChunkProcessor` 576 行、`TaskApplicationService` 543 行），prompt 模板硬编码在 Java 字符串中（`DeepseekChunkProcessor.java:104-184`，事实） |
| **测试覆盖** | 3 | 存在 `PackageStructureSmokeTest`（每模块一个）和 `common/util` 下的 5 个工具类测试（`AesCryptoUtilTest` 等，事实）。扣分：无业务逻辑测试、无集成测试、无 MockMvc 测试，核心编排逻辑未覆盖（合理推断） |
| **错误处理** | 3 | `GlobalExceptionHandler` 覆盖 Business/System/Validation/Request/通用异常（`GlobalExceptionHandler.java`，事实）。扣分：Worker 中错误分类粗糙，`resolveBusinessErrorCode` 仅映射 3 个码其余一律 `BUSINESS_ERROR`（`TaskCreateWorkerService.java:176-182`）；`finalizeChunk` 中聚合失败只 log 不重试不告警（`TaskExecutionApplicationService.java:251-270`，事实） |
| **安全设计** | 4 | 手机号 AES 加密 + SHA256 Hash 唯一约束（`offer-coming-sql.sql:14-15`，事实）；BCrypt 密码；JWT HMAC；登录失败锁定（`AuthApplicationService.java:321-342`）；CORS 限制方法。扣分：`jwtSecret` 默认值硬编码 `12345678901234567890123456789012`（`AuthApplicationService.java:54-55`，事实）；CORS `allowedOriginPatterns("*")` + `allowCredentials(true)` 同时开启（`SecurityConfig.java:53-56`，事实）——这在浏览器侧会拒绝凭证，但配置意图不安全 |
| **性能与扩展** | 3 | MQ 异步处理长任务合理；chunk 逐个串行处理（`TaskCreateWorkerService.java:41` for 循环，事实）无并行；`TaskExecutionApplicationService.recalculateTaskProgress` 每个 chunk 完成都全量扫描 chunks 重算（`TaskExecutionApplicationService.java:151-215`，事实）——O(n²) 复杂度；无缓存层（Redis 仅用于验证码/会话） |
| **可维护性** | 4 | 分层清晰、命名一致、Converter 隔离 DO/Domain、DTO 分层（Command/Result/Response）（事实）。扣分：prompt 与创作偏好逻辑耦合在 Worker 中，无法通过 admin 配置的 Prompt 模板动态替换（尽管有 `PromptTemplate` 表，但 `DeepseekChunkProcessor` 未使用，合理推断） |
| **文档完备性** | 5 | README 详尽，8 份设计文档（架构/数据库/需求/部署/YAML Schema/用户手册/生产部署），deploy 目录有 docker-compose + nginx + systemd（事实）。这是 5 个项目中文档最完整的（合理推断） |
| **部署友好度** | 4 | docker-compose 编排中间件、systemd service 文件、nginx 配置（前端/API/MinIO 三份）、`.env.production.example`（事实）。扣分：未提供后端 Dockerfile，需手动 `mvn` 构建（合理推断） |
| **复用性** | 3 | DDD 分层框架可复用，但核心业务逻辑（prompt、chunk 切分、聚合规则）与"小说转剧本"场景强耦合；`Result`/`PageResult`/异常体系是通用可复用资产（事实） |
| **商业化潜力** | 3 | 有完整的支付/充值/额度体系（`PaymentApplicationService`、`QuotaApplicationService`，事实），但支付是 Mock（`PaymentChannelEnum.MOCK`，`PaymentApplicationService.java:129`）；README 自述定位为"毕业设计/答辩"（`README.md:300-304`，事实），未体现真实商业化路径 |

**综合工程分：3.6 / 5**

---

## 优点

1. **DDD 分层教科书级落地**（事实）：Domain 纯接口、Application 编排、Infra 实现、Server/Worker 双入口，依赖方向严格，6 个模块职责清晰，是 Java 工程教学与实战的优秀范例。

2. **MQ 异步任务编排完整**（事实）：RabbitMQ 死信队列 + 手动 ACK/NACK + `x-retry-count` 重试计数 + 超限标记失败，`TaskMqConfig.java` 与 `TaskCreateMessageListener.java` 实现了生产级的消息可靠性模式。

3. **额度体系闭环**（事实）：预扣→实际消耗→退还→充值→预警通知→日志审计，`QuotaApplicationService` 覆盖了完整的额度生命周期，`QuotaLog` 记录 balanceBefore/balanceAfter 可追溯。

4. **LLM 输出强校验 + 重试**（事实）：`DeepseekChunkProcessor.parseAndValidateResult` 对 acts/scenes/characters/dialogueBeats/actionBeats 做 14 条非空与类型校验，校验失败用 `buildRetryPrompt` 重新调用，JSON 提取有 fence + 括号匹配双策略。

5. **安全合规意识强**（事实）：手机号 AES 加密存储 + Hash 唯一约束分离（`offer-coming-sql.sql:14-15`），密码 BCrypt，JWT HMAC-SHA，登录失败计数锁定，操作日志记录。

6. **文档与部署资料完备**（事实）：8 份设计文档 + docker-compose + nginx + systemd + `.env.example`，是审查的 5 个项目中文档与运维资料最完整的。

---

## 缺点 / 风险 / 改进优先级

### P0（高优先级）

1. **JWT 密钥硬编码默认值**（事实，`AuthApplicationService.java:54-55`、`JwtAuthenticationFilter.java:38`）：
   ```java
   @Value("${offer.auth.jwt-secret:12345678901234567890123456789012}")
   ```
   若生产环境未配置 `offer.auth.jwt-secret`，将使用硬编码密钥，任何拿到源码的人可伪造任意 token。建议：启动时强制校验密钥非默认值，或从 Vault/KMS 注入。

2. **CORS 配置安全隐患**（事实，`SecurityConfig.java:53-56`）：`allowedOriginPatterns("*")` + `allowCredentials(true)` 组合。虽然浏览器规范会拒绝此组合下的凭证请求，但意图不安全。建议：配置明确的允许域名列表。

3. **Chunk 串行处理**（事实，`TaskCreateWorkerService.java:41`）：for 循环逐 chunk 调用 LLM，长小说（如 200 chunk）处理时间将极长。建议：引入并行处理或 Worker 水平扩容（多实例消费同一队列）。

### P1（中优先级）

4. **进度重算 O(n²)**（事实，`TaskExecutionApplicationService.java:151-215`）：每个 chunk 完成都 `findByTaskId` 全量加载并遍历所有 chunk 重算 processed/success/failed 计数。对大任务性能不佳。建议：增量更新计数或用 Redis 计数器。

5. **聚合失败静默吞掉**（事实，`TaskExecutionApplicationService.java:251-270`）：`finalizeChunk` 中 `scriptAggregator.aggregate` 与 `profileGenerationService.generateFromScript` 失败只 log.error 不抛出，用户可能看到 chunk 成功但剧本/档案缺失。建议：失败时标记任务为 PARTIAL_FAILED 或增加重试。

6. **Prompt 模板未与 Admin 配置打通**（合理推断）：`offer-domain` 有 `PromptTemplate` 模型与 Repository，admin 有 Prompt 模板管理界面，但 `DeepseekChunkProcessor.buildPrompt` 硬编码了全部 prompt 文本（`DeepseekChunkProcessor.java:104-184`），未读取数据库模板。这是设计与实现的脱节。

7. **无事务保护**（合理推断）：`TaskApplicationService.createTask` 标注了 `@Transactional`（`TaskApplicationService.java:54`），但 `QuotaApplicationService.assertAndDeductQuota` 与 chunk 批量保存跨多个 Repository 调用，若中间失败可能额度已扣但 chunk 未建。Worker 侧 `finalizeChunk` 中 chunk 保存 + 聚合 + 档案生成无事务边界。

8. **Token 估算粗糙**（事实，`DeepseekChunkProcessor.java:561-565`）：`estimateTokenUsed = (sourceLength + responseLength) / 2`，纯字符数估算，非真实 token 计数。`TaskCostGuardService.estimateTokens` 也用 `text.length() * ratio`（`TaskCostGuardService.java:16-21`）。商业化场景下成本核算不准。

### P2（低优先级）

9. **贫血领域模型**（合理推断）：`Task`、`Novel` 等核心领域对象是纯 POJO（`Task.java` 全 getter/setter），业务规则散落在 Application 层。`Novel` 有少量行为方法（`markProcessed`、`validateCanCreateTask`），但 `Task` 状态流转逻辑全在 `TaskExecutionApplicationService`。

10. **测试覆盖不足**（事实）：仅 `PackageStructureSmokeTest` + 5 个工具类单元测试，核心编排逻辑（任务创建、chunk 处理、额度扣减、聚合）无测试覆盖。

11. **前端依赖版本用 `latest`**（事实，`offer-web/package.json:11-23`）：`"vue": "latest"`、`"axios": "latest"` 等，无法锁版本，存在构建不可复现风险。

---

## 复用性矩阵

| 资产 | 可复用性 | 说明 |
|---|---|---|
| DDD 四层模块骨架（common/domain/application/infra/server/worker） | 高 | 可直接作为 Spring Boot + MQ 项目的脚手架（事实） |
| `Result<T>` + `ResultCode` + `GlobalExceptionHandler` 统一响应体系 | 高 | 通用 Java Web 资产（`offer-common/.../result/Result.java`，事实） |
| RabbitMQ 死信 + 重试 + ACK 配置模式 | 高 | `TaskMqConfig` + `TaskCreateMessageListener` 可移植到任何异步任务场景（事实） |
| 额度（Quota）预扣/退还/日志/预警体系 | 中高 | 业务无关的额度管理可复用，但与 Token 估算耦合（事实） |
| JWT + Spring Security 无状态认证 + 登录锁定 | 中高 | 通用认证资产，需替换默认密钥（事实） |
| 手机号 AES + Hash 双字段存储模式 | 中 | 通用隐私数据存储模式（事实） |
| 章节树感知切分 + chunk 分片 | 中 | 与小说场景耦合，但切分框架可泛化（事实） |
| LLM 输出强校验 + 重试 + JSON 提取 | 中 | 通用 LLM 结果处理模式，但校验规则是剧本专属（事实） |
| 剧本聚合（actNumber/sceneNumber 重编号） | 低 | 强耦合剧本 YAML 结构（事实） |
| Prompt 硬编码模板 | 不可复用 | 写死在 Java 代码中，无法动态替换（事实） |
| Vue3 前端视图与路由 | 低 | 与后端 API 强耦合，视图组件可参考但不可直接复用（合理推断） |

---

## 可学习的内容

1. **DDD 多模块 Maven 工程的依赖管理实践**（`offer-code/pom.xml` 的 `dependencyManagement` + 子模块 `<dependencies>`，事实）：如何在多模块中统一版本、分层依赖、避免循环引用。

2. **RabbitMQ 生产级可靠性模式**（`TaskMqConfig.java` + `TaskCreateMessageListener.java`，事实）：死信交换机、死信队列、`x-retry-count` header 手动重试、`basicNack` requeue、超限 `basicReject` 进 DLQ——这是一套完整的消息可靠性处理范式。

3. **异步长文本 AI 任务的编排模式**（`TaskCreateWorkerService` + `TaskExecutionApplicationService`，事实）：任务→chunk→逐个处理→状态回写→进度重算→聚合→档案生成，是长文本 AI 处理的标准 pipeline。

4. **LLM 结构化输出的校验与重试策略**（`DeepseekChunkProcessor.java`，事实）：14 条校验规则 + 失败重试 + 双模式 JSON 提取（fence + 括号匹配），是处理 LLM 不可靠输出的实战模式。

5. **隐私数据的加密存储设计**（`offer-coming-sql.sql:14-15`，事实）：手机号 AES 加密存储 + SHA256 Hash 用于查询和唯一约束，密文不建索引，Hash 建唯一约束——这是隐私合规存储的标准做法。

6. **Spring AI 1.0.0-M6 的集成方式**（`DeepseekChunkProcessor.java:93-98`，事实）：`ChatClient.create(chatModel).prompt(prompt).call().content()` 的基础用法。

7. **小说文本预处理流水线**（`NovelTextPreprocessor.java` + `ChapterTreeExtractor.java`，事实）：编码检测→全角转半角→换行统一→广告/水印清理→零宽字符清理→章节树提取，是中文小说预处理的完整实践。

---

## YAML 摘要

```yaml
project: offer-coming
one_line_judgment: 面向"小说转剧本"长文本 AI 生成场景的 Java 多模块 DDD 工程，任务编排与 MQ 重试扎实，但 prompt 硬编码、并发与一致性缺乏事务保护，属准生产级作品
product_type: AI 长文本结构化转换工具（小说→剧本）
target_users: 编剧、内容创作者、影视行业从业者；README 自述定位为毕业设计/答辩/原型展示
core_loop: 上传 TXT→章节预处理→创建任务→MQ 投递→Worker 逐 chunk 调 LLM→校验聚合→在线编辑/导出剧本
architecture_style: DDD 四层（common/domain/application/infra）+ 双入口（server/worker）+ RabbitMQ 异步解耦
stack:
  backend: "Java 21, Spring Boot 3.2.5, Spring Cloud 2023.0.1, MyBatis-Plus 3.5.6, Spring AI 1.0.0-M6"
  frontend: "Vue3, Vite, Pinia, Element Plus, Monaco Editor, axios"
  middleware: "MySQL 8+, Redis, RabbitMQ 3+, MinIO"
  deploy: "Docker Compose, Nginx, systemd"
strongest_patterns:
  - DDD 多模块分层 + 依赖方向严格
  - RabbitMQ 死信队列 + 手动重试 + ACK/NACK
  - 额度预扣/退还/日志/预警闭环
  - LLM 输出 14 条强校验 + 失败重试 + 双模式 JSON 提取
  - 章节树感知切分 + SHA256 幂等
  - 手机号 AES 加密 + Hash 唯一约束
main_risks:
  - JWT 密钥硬编码默认值，生产环境若未配置可伪造 token
  - CORS allowedOriginPatterns("*") + allowCredentials(true) 配置不安全
  - Chunk 串行处理，长小说处理耗时极长
  - 进度重算 O(n²)，大任务性能差
  - 聚合失败静默吞掉，用户可能看到 chunk 成功但剧本缺失
  - Prompt 模板未与 Admin 配置打通，设计与实现脱节
  - 无事务保护，额度扣减与 chunk 创建可能不一致
  - 前端依赖用 latest 版本，构建不可复现
business_scenarios:
  - 小说 TXT 上传与章节预处理
  - AI 剧本转换任务（创建/取消/暂停/恢复/重试）
  - 剧本在线编辑（Monaco YAML）与导出
  - 故事档案自动生成
  - 额度管理与充值（Mock 支付）
  - 管理端治理（用户/任务/配置/Prompt/日志）
reusable_assets:
  - DDD 四层模块骨架
  - Result + ResultCode + GlobalExceptionHandler 统一响应体系
  - RabbitMQ 死信 + 重试 + ACK 配置模式
  - JWT + Spring Security 无状态认证
  - 额度预扣/退还/日志体系
  - 手机号 AES + Hash 双字段存储模式
non_reusable_parts:
  - 剧本聚合与 actNumber/sceneNumber 重编号逻辑
  - Prompt 硬编码模板
  - Vue3 前端视图与路由
  - 剧本 YAML 结构校验规则
scores:
  product: 3
  architecture: 4
  engineering: 3
  reuse: 3
  commercialization: 3
evidence:
  - "offer-code/pom.xml:15-22（6 模块定义）"
  - "offer-worker/.../TaskCreateMessageListener.java:29-98（MQ 消费 + 重试 + 死信）"
  - "offer-application/.../TaskApplicationService.java:54-122（任务创建 + chunk 切分 + 额度预扣）"
  - "offer-worker/.../DeepseekChunkProcessor.java:48-91（LLM 调用 + 校验 + 重试）"
  - "offer-application/.../TaskExecutionApplicationService.java:151-272（进度重算 + 聚合触发）"
  - "offer-application/.../QuotaApplicationService.java:37-109（额度预扣/退还/充值）"
  - "offer-server/.../SecurityConfig.java:34-56（安全配置 + CORS）"
  - "offer-application/.../AuthApplicationService.java:54-55（JWT 密钥默认值）"
  - "offer-code/db/offer-coming-sql.sql:14-15（手机号加密存储）"
  - "offer-infra/.../text/preprocess/NovelTextPreprocessor.java（文本预处理流水线）"
confidence: high
```
