# gisfy 项目审查报告

> 审查日期: 2026-08-15
> 审查方法: qiniu-project-audit (6 步法)
> 证据纪律: 所有结论标注 [事实]/[推断]/[假设]，引用文件路径与行号

---

## 第 1 步: 确立项目边界

### 1.1 项目定位

gisfy 是一个 **AI 游戏素材生成平台**，面向游戏开发者提供文生图、图生图、精灵图合成(spritesheet)、背景归一化等游戏美术资产生产能力。

[事实] README.md 明确: Next.js 16.2.6 + React 19.2.4，使用阿里百炼 `wanx2.1-t2i-turbo` 模型，Supabase 存储，Upstash Redis 会话管理，Vercel 部署。

### 1.2 目录结构

```
gisfy/
├── src/
│   ├── app/
│   │   ├── api/
│   │   │   ├── auth/          # 注册/登录
│   │   │   ├── generate/      # 文生图 (异步任务+轮询)
│   │   │   ├── upload/        # 上传到Supabase
│   │   │   ├── assets/        # 资产CRUD
│   │   │   ├── spritesheet/   # 精灵图合成
│   │   │   ├── polish/        # 图像优化
│   │   │   └── vision/        # 视觉描述
│   │   └── (页面路由)
│   ├── lib/
│   │   ├── generation.ts      # 生成任务核心逻辑
│   │   ├── ali.ts             # 阿里百炼API封装
│   │   ├── auth.ts            # Redis会话管理
│   │   ├── spritesheet.ts     # 精灵图合成 (sharp)
│   │   └── supabase.ts        # Supabase客户端
│   └── prisma/
│       └── schema.prisma      # 数据模型
├── tests/
│   └── api-routes.test.ts     # E2E测试
└── package.json
```

### 1.3 边界确认

- **前端**: Next.js 16 App Router, React 19, Turbopack [事实, package.json]
- **后端**: Next.js API Routes (全栈一体) [事实, `src/app/api/`]
- **数据库**: Supabase (PostgreSQL) + Prisma ORM [事实, `prisma/schema.prisma`]
- **会话**: Upstash Redis [事实, `src/lib/auth.ts:1-96`]
- **AI**: 阿里百炼 DashScope (wanx2.1-t2i-turbo) [事实, `src/lib/ali.ts`]
- **图像处理**: sharp [事实, `src/lib/spritesheet.ts`]

---

## 第 2 步: 还原产品/业务闭环

### 2.1 核心用户旅程

```
注册/登录 ──▶ 输入Prompt+风格 ──▶ AI生成图片(异步)
                                    │
                    ┌───────────────┼───────────────┐
                    ▼               ▼               ▼
              上传到Supabase    精灵图合成      背景归一化
                    │               │               │
                    ▼               ▼               ▼
              资产列表管理      下载PNG+JSON    下载处理图
              (查看/删除)
```

### 2.2 业务闭环分析

[事实] 完整的资产生命周期: 生成 → 上传 → 存储 → 列表 → 删除 [`tests/api-routes.test.ts:1-135` E2E测试覆盖全流程]

[事实] 异步生成模式: `POST /api/generate` 返回 `taskId` + `status: queued` → 前端轮询 `GET /api/generate/status?taskId=` → `completed` [`tests/api-routes.test.ts:29-51`]

[事实] 资产模型: `Asset { id, userId, cdnUrl, prompt, style, type, size, seed, cost, duration, createdAt }` [`prisma/schema.prisma`]

[推断] 产品定位为**游戏开发者美术工具链**，精灵图合成是核心差异化能力。

### 2.3 商业化潜力

[假设] 商业化路径清晰: 按 `cost` (生成成本) 计费 + 按生成次数订阅。`Asset.cost` 字段的存在表明已预留计费数据结构。

---

## 第 3 步: 还原技术架构

### 3.1 架构总览

```
┌──────────────────────────────────────────────────────┐
│  Next.js 16 (App Router, React 19, Turbopack)        │
│                                                       │
│  ┌─────────┐  ┌──────────┐  ┌────────────────────┐  │
│  │ Auth    │  │ Generate │  │ Assets/Spritesheet │  │
│  │(Redis)  │  │ (异步任务) │  │ (sharp处理)        │  │
│  └────┬────┘  └────┬─────┘  └────────┬───────────┘  │
└───────┼────────────┼────────────────┼───────────────┘
        │            │                │
        ▼            ▼                ▼
   ┌─────────┐ ┌──────────────┐ ┌──────────┐
   │ Upstash │ │ 阿里百炼     │ │ Supabase │
   │ Redis   │ │ DashScope    │ │ (PG+存储)│
   │(会话TTL)│ │ (异步图生成)  │ │ Prisma   │
   └─────────┘ └──────┬───────┘ └──────────┘
                       │
                ┌──────┴──────┐
                │ generation  │
                │ -queue      │
                │ (内存队列)   │
                └─────────────┘
```

### 3.2 关键技术决策

**[事实] 异步生成 + 轮询模式** (`src/lib/generation.ts:74-258`):
- `startGenerationTask()` 将任务入队 `generation-queue`
- `runGeneration()` 执行实际生成
- `Promise.race` 实现超时控制
- 无 `ALI_API_KEY` 时使用 mock fallback (返回占位图)
- 重试机制: 2 次重试
- `sharp` 归一化背景
- Supabase 上传 + Prisma `upsertAssets`

**[事实] 阿里百炼异步任务模式** (`src/lib/ali.ts:1-153`):
- `generateWithAli()` 发送请求时带 `X-DashScope-Async: enable` header
- `pollTask()` 以 2 秒间隔轮询，最多 45 次 (90 秒超时)
- `urlToBase64()` 下载结果图

**[事实] Redis 会话管理** (`src/lib/auth.ts:1-96`):
- `createSession()` / `destroySession()` / `validateSession()`
- httpOnly cookie (`gisfy_sid`), 3 天 TTL
- `secure` 标志在生产环境启用

**[事实] 精灵图合成** (`src/lib/spritesheet.ts:51-127`):
- `packSpritesheet()` 使用 `sharp.composite()` 合成
- `calcLayout()` 支持三种布局: strip / grid / sqrt(自动)
- `exportSpritesheetJson()` 支持 aseprite / strip / grid 三种 JSON 格式
- 同尺寸校验: 不同尺寸图片会报错

**[事实] 认证实现** (`src/app/api/auth/register/route.ts:1-56`):
- zod 输入验证
- `bcrypt.hash(password, 12)` 密码加密
- Supabase insert + 创建会话 + 设置 cookie

### 3.3 数据模型

[事实] `prisma/schema.prisma`:
- `User`: id, email, name, password, timestamps
- `Asset`: id, userId, cdnUrl, prompt, style, type, size, seed, cost, duration, createdAt
- 索引: `@@index([userId, createdAt(sort: Desc)])` — 按用户+时间倒序查询优化

---

## 第 4 步: 工程质量评分 (1-5)

| 维度 | 评分 | 理由 |
|------|------|------|
| 产品完整度 | 4 | 完整资产生命周期 + E2E测试覆盖 + 多功能 (生成/合成/优化) |
| 架构设计 | 4 | 异步任务+轮询、Redis会话、Prisma+Supabase分层清晰、sharp图像处理专业 |
| 工程质量 | 3.5 | 有E2E测试和ESLint；但内存队列不持久化、generate接口无认证、mock fallback在生产有风险 |
| 可复用性 | 4 | 精灵图合成模块高度可复用；ali.ts异步轮询模式可复用；auth.ts会话模式标准 |
| 商业化 | 3.5 | cost字段预留计费、资产模型完整；但缺少支付/配额/多租户 |

**综合评分: 3.8/5**

### 4.1 关键工程问题

**[事实] 严重: generate 接口无认证** — `POST /api/generate` 的 `userId` 默认为 `"default"`，未验证用户身份 [`src/app/api/generate/route.ts:1-26`]。任何人可触发图片生成，产生 API 费用。

**[事实] 中等: 内存队列不持久化** — `generation-queue` 是内存队列，服务重启丢失任务 [`src/lib/generation.ts:74-258`]。

**[事实] 中等: mock fallback 在生产环境有风险** — 无 `ALI_API_KEY` 时返回占位图，生产环境可能静默降级 [`src/lib/generation.ts`]。

**[推断] 低: Redis 单点** — Upstash Redis 作为唯一会话存储，无降级方案。

---

## 第 5 步: 优缺点与可复用性评估

### 5.1 优点

1. **[事实] 精灵图合成模块专业** — 支持 strip/grid/sqrt 三种布局 + aseprite/strip/grid 三种 JSON 格式，使用 sharp composite 高效合成 [`spritesheet.ts:51-159`]
2. **[事实] 异步生成+轮询架构完善** — DashScope async header + pollTask (2s间隔, 45次上限) + Promise.race 超时 + 2次重试 [`ali.ts:1-153`, `generation.ts:74-258`]
3. **[事实] 认证安全实践良好** — bcrypt(12) + httpOnly cookie + secure in prod + Redis TTL [`auth.ts:1-96`, `register/route.ts`]
4. **[事实] E2E 测试覆盖核心流程** — generate→poll→upload→assets list/delete 完整测试 [`tests/api-routes.test.ts:1-135`]
5. **[事实] 数据模型设计合理** — Asset 索引 `@@index([userId, createdAt(sort: Desc)])` 优化用户资产查询 [`schema.prisma`]

### 5.2 缺点

1. **[事实] 严重: generate 接口无认证** — userId 默认 "default"，可被滥用
2. **[事实] 内存队列不持久化** — 重启丢任务
3. **[事实] mock fallback 生产风险** — 静默降级
4. **[推断] 无配额/限流** — 未发现 rate limit 中间件

### 5.3 可复用资产

| 资产 | 可复用性 | 说明 |
|------|----------|------|
| `spritesheet.ts` 精灵图合成 | 极高 | 独立模块，sharp composite + 多格式JSON导出，可直接用于任何游戏开发工具 |
| `ali.ts` DashScope 异步轮询模式 | 高 | async task + poll 模式可复用于任何异步 AI API |
| `auth.ts` Redis 会话管理 | 高 | 标准 session 模式，可复用 |
| `generation.ts` 异步任务+重试+超时 | 高 | Promise.race 超时 + 重试 + mock fallback 模式 |
| Prisma schema (User+Asset) | 中 | 资产管理基础模型 |

### 5.4 不可复用部分

- `generation-queue` 内存队列 (应替换为 Redis/BullMQ)
- generate 路由的无认证设计 (需添加 auth)
- mock fallback (生产环境应移除或明确告警)

---

## 第 6 步: 提取学习内容

### 6.1 架构模式学习

**异步 AI API 调用模式 (DashScope)**
```
1. POST 请求 + X-DashScope-Async: enable header → 返回 task_id
2. GET /tasks/{task_id} 轮询 (固定间隔, 最大次数)
3. status: PENDING → SUCCEEDED → 下载结果
4. 超时 (Promise.race) + 重试 (N次) + 降级 (mock/默认图)
```
- 学习点: 异步 AI API 需要完整的"提交-轮询-超时-重试-降级"链路

**精灵图合成布局算法**
```
strip: cols = total (单行)
grid:  cols = min(config.columns, total)
sqrt:  cols = ceil(sqrt(total))  (近似方形)
rows = ceil(total / cols)
```
- 学习点: 根据用途选择布局策略，strip 适合动画帧序列，grid 适合图集

**会话安全实践**
```
bcrypt(rounds=12) → Redis session (TTL=3天) → httpOnly cookie + secure(prod)
```
- 学习点: httpOnly 防 XSS 窃取, secure 防 HTTP 明文, bcrypt(12) 平衡安全与性能

### 6.2 反模式学习

1. **generate 接口无认证** — 即使有 auth 系统，核心付费接口也必须验证身份
2. **内存队列** — 生产环境任务队列应使用持久化方案 (Redis/BullMQ/SQS)
3. **静默 mock fallback** — 降级时应明确告知用户，而非静默返回占位数据

### 6.3 可复用代码片段

**DashScope 异步轮询** (伪代码):
```typescript
async function generateWithAli(prompt, options) {
  const res = await fetch(endpoint, {
    headers: { "X-DashScope-Async": "enable", Authorization: `Bearer ${key}` },
    body: JSON.stringify({ model, input: { prompt } })
  });
  const { output: { task_id } } = await res.json();
  return pollTask(task_id, { interval: 2000, maxAttempts: 45 });
}

async function pollTask(taskId, { interval, maxAttempts }) {
  for (let i = 0; i < maxAttempts; i++) {
    const { status, output } = await checkTask(taskId);
    if (status === "SUCCEEDED") return output;
    if (status === "FAILED") throw new Error("task failed");
    await sleep(interval);
  }
  throw new Error("timeout");
}
```

**精灵图布局计算** (伪代码):
```typescript
function calcLayout(total, { format, columns }) {
  const cols = format === "strip" ? total
    : columns ? Math.min(columns, total)
    : Math.ceil(Math.sqrt(total));
  return { cols, rows: Math.ceil(total / cols) };
}
```

---

## YAML 摘要

```yaml
project: gisfy
one_line_judgment: AI游戏素材生成平台，精灵图合成是核心差异化能力，工程化程度较高但generate接口无认证是严重隐患
product_type: AI游戏美术资产生成平台 (文生图+精灵图合成+背景归一化)
target_users: 游戏开发者、独立游戏团队、游戏美术师
core_loop: 输入Prompt+风格→AI异步生成→上传Supabase→资产管理/精灵图合成
architecture_style: Next.js全栈一体 (App Router)，异步任务+轮询，Redis会话+Supabase存储+Prisma ORM
stack:
  - Next.js 16.2.6 (App Router, Turbopack)
  - React 19.2.4
  - Prisma ORM + Supabase (PostgreSQL)
  - Upstash Redis (会话管理)
  - 阿里百炼 DashScope (wanx2.1-t2i-turbo)
  - sharp (图像处理/精灵图合成)
  - bcrypt + zod (认证+验证)
  - Vitest (测试)
strongest_patterns:
  - 精灵图合成 (strip/grid/sqrt布局 + aseprite/strip/grid JSON格式)
  - DashScope异步任务+轮询 (X-DashScope-Async + pollTask)
  - Redis会话管理 (httpOnly cookie + bcrypt(12) + TTL)
  - 异步生成+超时+重试+降级链路
main_risks:
  - 严重: generate接口无认证 (userId默认default，可被滥用产生费用)
  - 中等: 内存队列不持久化 (重启丢任务)
  - 中等: mock fallback生产静默降级风险
  - 低: 无配额/限流
business_scenarios:
  - 游戏角色/道具文生图
  - 精灵图动画帧合成
  - 背景归一化处理
  - 游戏美术资产管理
reusable_assets:
  - spritesheet.ts精灵图合成模块 (极高)
  - ali.ts DashScope异步轮询模式 (高)
  - auth.ts Redis会话管理 (高)
  - generation.ts异步任务+重试+超时模式 (高)
  - Prisma User+Asset模型 (中)
non_reusable_parts:
  - generation-queue内存队列 (应替换为持久化方案)
  - generate路由无认证设计 (需添加auth)
  - mock fallback (生产应移除或告警)
scores:
  product: 4
  architecture: 4
  engineering: 3.5
  reuse: 4
  commercialization: 3.5
evidence:
  - "[事实] README: Next.js 16.2.6 + React 19.2.4 + 阿里百炼wanx2.1-t2i-turbo"
  - "[事实] 精灵图合成: spritesheet.ts:51-159 (strip/grid/sqrt + aseprite格式)"
  - "[事实] DashScope异步: ali.ts:1-153 (X-DashScope-Async + pollTask 2s/45次)"
  - "[事实] Redis会话: auth.ts:1-96 (httpOnly cookie + 3天TTL + secure)"
  - "[事实] generate无认证: generate/route.ts:1-26 (userId默认default)"
  - "[事实] E2E测试: api-routes.test.ts:1-135"
  - "[事实] Asset模型+索引: schema.prisma (@@index userId+createdAt)"
  - "[事实] bcrypt(12): register/route.ts:1-56"
  - "[推断] 无配额/限流"
  - "[假设] 商业化路径: cost字段预留计费"
confidence: high
```
