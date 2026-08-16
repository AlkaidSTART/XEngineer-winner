# PRysm 审查报告

## 一句话判断

基于 GitHub Actions 的 AI PR 代码评审助手，采用"确定性规则引擎+LLM 语义审查"双引擎架构，以 Java 21 + Spring Boot 4 实现，工程结构规范、测试覆盖优秀、安全考量周到，但规则覆盖面窄且产品形态受限于 GitHub Actions 触发模式。

## 项目地图

| 维度 | 信息 |
|------|------|
| 项目名称 | PRysm |
| 类型 | GitHub Actions CI 工具（一次性执行 jar） |
| 语言/框架 | Java 21 / Spring Boot 4.0.6 / Maven |
| 构建工具 | Maven (mvnw) |
| 源码规模 | 59 个主源文件（6,816 行）+ 32 个测试文件（4,960 行） |
| 核心入口 | `PrReviewRunner.java`（ApplicationRunner，Spring Boot 启动后触发） |
| 外部服务 | GitHub REST API（PR diff/评论）、OpenAI 兼容 LLM（默认千问 DashScope） |
| 部署形态 | GitHub Actions 中 `java -jar prysm.jar`，reusable workflow 跨仓库复用 |
| CI/CD | 4 个 workflow（ci/release/prysm-review/prysm-review-reusable） |
| 仓库状态 | 1 次 git commit |

**目录结构（按模块）：**
```
src/main/java/com/hdg/prysm/
├── PrysmApplication.java          # Spring Boot 入口
├── runner/PrReviewRunner.java     # 审查流程编排（562行，核心）
├── context/                       # PR 上下文解析（GitHub Actions 环境）
├── diff/                          # PR diff 获取与解析
├── review/                        # 审查上下文加载（代码片段构建）
├── enrichment/                    # 上下文增强（PR 标题/正文/commit message）
├── selection/                     # 文件筛选
├── budget/                        # 上下文预算控制
├── assembly/                      # 审查输入组装
├── rule/                          # 确定性规则引擎（冲突标记+调试输出）
├── llm/                           # LLM 审查引擎（OpenAI 兼容）
├── optimization/                  # LLM 优化（fast-path/max-tokens/compact-prompt）
├── result/                        # 结果聚合、去重、排序
├── quality/                       # 质量门控（过滤低质量 finding）
├── comment/                       # PR 评论渲染
├── github/                        # GitHub API 封装
├── trace/                         # 审查链路追踪
└── execution/                     # 执行模型（ReviewFinding/PromptPayload等）
```

## 产品与商业场景

**目标用户：** GitHub 仓库维护者、开发团队、开源项目作者。

**场景痛点：** PR 审查中信息分散（需翻看 diff、文件、commit），人工定位风险慢，Review 建议质量不稳定且依赖个人经验。重复性的变更梳理和风险提示耗费大量时间。

**输入/处理/输出/反馈闭环：**
- 输入：开发者创建/更新 Pull Request → GitHub Actions 触发 `pull_request_target`
- 处理：解析 PR 上下文 → 获取 diff+文件+元数据 → 代码片段增强 → 文件筛选+预算控制 → 规则引擎(确定性) + LLM引擎(语义) → 结果聚合去重排序
- 输出：快速审查评论先写入 PR → 深度审查完成后更新同一条评论
- 反馈：评论包含审查概览/变更总结/规则摘要/风险代码/Review 建议

**独特价值：** 确定性规则+LLM 双引擎——规则引擎兜底明确风险（合并冲突标记、调试输出），LLM 补充语义风险，避免完全依赖模型判断的误报漏报；快速+深度两阶段评论，先返回明显风险再更新完整结果。

**商业化分析：**
- 付费方：开发团队/企业（LLM API 成本由接入方承担，工具本身免费）
- 获客渠道：GitHub Marketplace + 开源社区 + 演示仓库免配置体验
- 交付成本：零基础设施成本（纯 GitHub Actions），接入只需复制 workflow + 配置 secret
- 持续使用理由：每个 PR 自动触发，降低人工 Review 负担

## 架构拆解

### 文字架构图

```
GitHub Actions (pull_request_target)
    │
    v
PrReviewRunner (ApplicationRunner, Spring Boot 启动后执行)
    │
    ├─[1] PrContextResolver → 从 GITHUB_ACTIONS 环境解析 owner/repo/PR号
    │
    ├─[2] GithubPrDiffProvider → GitHub API 获取 PR diff/文件/元数据
    │       (fetch-depth=1 checkout, GitHub REST API)
    │
    ├─[3] PrReviewContextLoader → 为变更文件构建代码片段（邻近上下文）
    │
    ├─[4] ReviewFileSelectionService → 按文件类型/优先级筛选进入模型的内容
    │
    ├─[5] ReviewContextBudgetService → 上下文预算控制（max-total-context-chars=40000）
    │
    ├─[6] ReviewExecutionInputAssembler → 组装审查输入
    │
    ├─[7] ReviewContextEnrichmentService → 补充 PR 标题/正文/commit message
    │
    ├─[8a] RuleEngineRunner → BuiltInRuleEngine
    │       ├── 合并冲突标记检测（<<<<<<< / ======= / >>>>>>>）
    │       └── Java System.out.print 调试输出检测
    │
    ├─[8b] 快速审查：LlmReviewRunner(fast-model=qwen-turbo) → 写入 PR 评论
    │
    ├─[9] LlmOptimizationPlanner → fast-path/max-tokens/compact-prompt 优化决策
    │
    ├─[10] LlmReviewRunner(deep-model) → OpenAI 兼容 Chat Completions
    │       (temperature=0, response_format=json_object, max_tokens=800)
    │
    ├─[11] ReviewFindingQualityGate → 过滤低质量 finding
    │
    ├─[12] ReviewResultAggregator → 聚合+去重+排序（规则+LLM finding）
    │
    └─[13] ReviewCommentRenderer → 渲染 Markdown 评论 → 更新同一条 PR 评论
```

### 请求追踪：一次完整的 PR 审查

1. PR 创建 → GitHub Actions 触发 `prysm-review-reusable.yml`，fast-review + deep-review 两 job 串行
2. `PrReviewRunner.run()`（`PrReviewRunner.java:139`）检查 `GITHUB_ACTIONS` 环境变量，非 CI 环境跳过
3. `PrContextResolver.resolve()` 从 `GITHUB_REPOSITORY`/`GITHUB_REF` 解析 owner/repo/PR号
4. `GithubPrDiffProvider.fetch()` 调用 GitHub API 获取 diff、文件列表、PR 标题正文
5. `PrReviewContextLoader.load()` 为每个变更文件提取邻近代码片段（`window-lines=20`, `max-snippets-per-file=3`）
6. `ReviewFileSelectionService.select()` + `ReviewContextBudgetService.allocate()` 筛选文件并控制上下文预算（`max-total-context-chars=40000`）
7. `RuleEngineRunner.run()` → `BuiltInRuleEngine.run()` 扫描 patch 新增行和 snippet（`BuiltInRuleEngine.java:33-51`）
8. 快速审查：`writeFastReviewComment()` 用 fast-model 调用 LLM + 规则结果聚合 → 创建/更新 PR 评论（`PrReviewRunner.java:413-495`）
9. 深度审查：`LlmReviewRunner.run()` 用 deep-model 调用 LLM（`OpenAiCompatibleLlmReviewClient.java:181-206`），temperature=0 + json_object 响应格式
10. `ReviewFindingQualityGate.filterDeepReview()` 过滤低质量 finding
11. `ReviewResultAggregator.aggregate()` 聚合规则+LLM finding，去重排序
12. `ReviewCommentRenderer.render()` 渲染 Markdown → 更新同一条 PR 评论

### 关键设计决策

- **双引擎架构**：确定性规则（`BuiltInRuleEngine`）+ LLM 语义审查（`LlmReviewRunner`），规则兜底明确风险，LLM 补充语义分析
- **快速+深度两阶段评论**（`PrReviewRunner.java:293-302`）：fast-review 先写评论（qwen-turbo），deep-review 完成后更新同一条评论，优先返回明显风险
- **上下文预算控制**（`application.yml`: `max-total-context-chars=40000`）：大 diff 时按优先级筛选文件并截断，控制 LLM 输入成本
- **LLM 优化策略**（`optimization/` 包）：fast-path（小 PR 用 fast-model）、max-tokens 限制、compact-prompt 压缩
- **Trace 全链路追踪**（`trace/` 包）：每个步骤记录 span + 状态 + 指标，输出审查链路摘要便于定位失败

## 工程评分

| 维度 | 分数 | 证据 |
|------|------|------|
| 产品完成度 | 4 | PR 审查全链路完整（上下文→规则→LLM→聚合→评论），跨仓库 reusable workflow，release jar |
| 架构边界 | 5 | 59 个类按模块清晰划分（context/diff/review/rule/llm/result/quality/comment/trace），Spring DI 注入 |
| 可维护性 | 5 | 模块化优秀，每个类职责单一，命名规范，SLF4J 日志，配置外部化 |
| 可测试性 | 5 | 32 个测试文件覆盖 4,960 行，几乎所有模块有对应测试（含 mock 和真实 API 测试） |
| 可观测性 | 4 | Trace 全链路追踪（span/状态/指标），SLF4J 结构化日志；但无外部指标导出 |
| 安全隐私 | 4 | pull_request_target + 独立目录 checkout + 可信 jar 运行；API Key 走 GitHub Secrets 不入仓库 |
| 性能并发 | 3 | fast+deep 两 job 串行（并发cancel-in-progress）；上下文预算控制成本；但无并行文件审查 |
| 资源释放 | 3 | Spring Boot 一次性执行后退出；HttpClient 无显式关闭但 JVM 退出回收 |
| 成本控制 | 4 | 上下文预算+fast-path+compact-prompt+max-tokens 限制 LLM 成本；concurrency 取消重复触发 |
| 部署恢复 | 4 | reusable workflow 跨仓库复用，release jar 优先下载+Maven fallback，artifact 传递 |
| 文档 | 4 | README 详尽（架构/配置/接入/FAQ/安全），演示仓库免配置体验；缺架构设计文档 |
| 上手难度 | 4 | Fork 演示仓库即可免配置体验；正式接入只需复制 workflow + 配置 secret |

### 问题分级

**阻断级：** 无

**重要级：**
- 内置规则覆盖面极窄：仅检测合并冲突标记和 Java `System.out.print`（`BuiltInRuleEngine.java:136-155`），不支持其他语言/其他规则类型
- 仅支持 PR 总评论，不支持行级 review comment（README 限制章节已承认）
- `spring-boot-starter-webmvc-test` 在 pom.xml 中作为 test scope 依赖，但实际项目 `web-application-type: none`（非 Web 应用），依赖可能冗余

**一般级：**
- LLM 审查依赖模型输出 JSON 格式正确性，`LlmReviewResponseParser` 解析失败时降级处理但可能丢失 finding
- `application.yml` 中 `max-total-context-chars=40000` 为硬编码默认值，大仓库可能不够
- 代码片段窗口 `window-lines=20` 可能不足以理解复杂变更上下文
- `.gitignore` 排除了 `src/main/resources/` 下的中文文档（架构.md/提交规范.jpg），这些是过程文档但可能影响可追溯性

**建议级：**
- 支持自定义规则（Semgrep/Checkstyle 集成已在注释中提及但未实现）
- 增加 GitLab/Gitee 平台支持
- GitHub App 模式降低单仓库接入成本

## 优点

1. **双引擎架构设计**：确定性规则兜底明确风险 + LLM 补充语义分析，避免完全依赖模型的误报漏报，是 AI 代码审查的合理架构（`BuiltInRuleEngine.java` + `LlmReviewRunner.java`）
2. **测试覆盖优秀**：32 个测试文件 4,960 行，覆盖几乎所有模块，测试代码量占主代码 73%，在五个项目中最高
3. **快速+深度两阶段评论**：fast-review 先返回明显风险，deep-review 完成后更新，优先保证响应速度（`PrReviewRunner.java:293-302, 413-495`）
4. **Trace 全链路追踪**：每个步骤记录 span + 状态（SUCCESS/DEGRADED/SKIPPED/FAILED）+ 指标（文件数/字符数/token用量），便于定位失败（`trace/` 包）
5. **跨仓库 reusable workflow**：接入只需复制一个 workflow + 配置一个 secret，零基础设施成本（`prysm-review-reusable.yml`）
6. **安全考量周到**：pull_request_target + 独立目录 checkout + 可信 jar 运行，避免执行不可信 PR 脚本（README 安全说明）
7. **LLM 成本控制**：上下文预算 + fast-path + compact-prompt + max-tokens 四重优化（`optimization/` 包）

## 缺点风险与改进优先级

| 优先级 | 问题 | 影响 | 建议 |
|--------|------|------|------|
| P1 | 规则覆盖面极窄 | 仅2条规则，实用价值受限 | 扩展安全规则/测试覆盖规则/自定义规则 |
| P1 | 不支持行级评论 | 无法精确定位代码行 | 扩展 GitHub review comment API |
| P2 | LLM JSON 解析依赖 | 模型输出格式错误时降级 | 增加重试 + 多格式解析容错 |
| P2 | 上下文预算硬编码 | 大仓库不够灵活 | 按仓库规模动态调整 |
| P3 | 仅支持 GitHub | 平台受限 | 扩展 GitLab/Gitee |
| P3 | webmvc-test 依赖冗余 | 构建体积 | 替换为 spring-boot-starter-test |

## 复用性矩阵

| 部分 | 评级 | 说明 |
|------|------|------|
| 双引擎审查架构 | 可直接复用 | 规则+LLM 双引擎模式可迁移到任何代码审查场景 |
| 上下文预算控制 | 可直接复用 | 文件筛选+字符预算+截断逻辑通用 |
| Trace 全链路追踪 | 可直接复用 | span/状态/指标的追踪框架可迁移到任何流水线 |
| GitHub API 封装 | 可直接复用 | PR diff 获取+评论回写的封装 |
| LLM 优化策略 | 可直接复用 | fast-path/max-tokens/compact-prompt 优化模式 |
| BuiltInRuleEngine | 改造后复用 | 框架可复用，规则需大幅扩展 |
| reusable workflow | 可直接复用 | 跨仓库 workflow 复用模式 |
| PrReviewRunner | 不应复用 | 562 行编排逻辑，与业务深度耦合 |

**复用评分：** 技术 4 / 产品 3 / 商业 3

## 值得学习的内容

1. **【初学者】Spring Boot 一次性任务模式**：`ApplicationRunner` + `web-application-type: none` 适合 CI/CD 中的批处理工具
2. **【初学者】GitHub Actions reusable workflow**：`workflow_call` 实现跨仓库 workflow 复用，接入只需一行 `uses:`
3. **【进阶者】双引擎审查架构**：确定性规则 + LLM 语义分析的分工——规则处理明确问题（零误报），LLM 处理语义问题（覆盖面广）
4. **【进阶者】快速+深度两阶段响应**：先用 fast-model 返回初步结果，再用 deep-model 更新完整结果，平衡速度与质量
5. **【进阶者】LLM 成本控制四重优化**：上下文预算 + fast-path 分流 + compact-prompt 压缩 + max-tokens 限制
6. **【可复刻实验】** Trace 全链路追踪框架（span+状态+指标）可迁移到任何多步骤流水线
7. **【可迁移模式】** pull_request_target + 独立目录 checkout 的安全模式可迁移到任何处理不可信 PR 的 CI 工具

```yaml
project: PRysm
one_line_judgment: "基于 GitHub Actions 的 AI PR 代码评审助手，规则+LLM 双引擎架构，工程规范和测试覆盖优秀，但规则覆盖面窄"
product_type: "GitHub Actions CI 工具（一次性执行 jar）"
target_users: ["GitHub 仓库维护者", "开发团队", "开源项目作者"]
core_loop: "PR创建触发 → 解析上下文 → 获取diff → 规则引擎+LLM双引擎审查 → 聚合去重 → 快速评论+深度更新"
architecture_style: "Spring Boot 一次性任务 + 模块化分层 + 双引擎审查"
stack: ["Java 21", "Spring Boot 4", "Maven", "GitHub Actions", "GitHub REST API", "OpenAI兼容LLM", "Lombok", "SLF4J"]
strongest_patterns: ["规则+LLM双引擎", "快速+深度两阶段评论", "Trace全链路追踪", "上下文预算控制", "LLM成本四重优化", "跨仓库reusable workflow", "pull_request_target安全模式"]
main_risks: ["规则覆盖面极窄(仅2条)", "不支持行级评论", "LLM JSON解析依赖", "上下文预算硬编码", "仅支持GitHub"]
business_scenarios: ["GitHub PR自动审查", "团队代码质量门禁", "开源项目贡献审查", "变更风险评估", "Review建议生成"]
reusable_assets: ["双引擎审查架构", "上下文预算控制", "Trace全链路追踪框架", "GitHub API封装", "LLM优化策略", "reusable workflow模板"]
non_reusable_parts: ["PrReviewRunner 562行编排", "BuiltInRuleEngine仅2条规则", "webmvc-test冗余依赖"]
scores:
  product: 4
  architecture: 5
  engineering: 5
  reuse: 4
  commercialization: 3
evidence: ["PrReviewRunner.java:139-411(审查流程编排)", "PrReviewRunner.java:293-302(快速+深度两阶段)", "PrReviewRunner.java:413-495(快速评论)", "BuiltInRuleEngine.java:33-51(规则引擎)", "BuiltInRuleEngine.java:136-155(仅2条规则)", "OpenAiCompatibleLlmReviewClient.java:181-206(LLM调用)", "OpenAiCompatibleLlmReviewClient.java:211-228(请求体构建)", "application.yml(配置外部化)", ".github/workflows/prysm-review-reusable.yml(跨仓库workflow)", "src/test/(32个测试文件4960行)"]
confidence: "高"
```
