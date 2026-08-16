# voice_input 项目审查报告

> 审查日期: 2026-08-15
> 审查方法: qiniu-project-audit (6 步法)
> 证据纪律: 所有结论标注 [事实]/[推断]/[假设]，引用文件路径与行号

---

## 第 1 步: 确立项目边界

### 1.1 项目定位

voice_input 是一个 **AI 文本润色 + 语音转写 Web 应用**，提供"边说边改"的写作辅助体验。

[事实] 项目根目录 `/Users/allure/Desktop/七牛云项目/voice_input/` 包含 `backend/` 和 `frontend/` 两个子目录，是标准的前后端分离架构。

### 1.2 目录结构

```
voice_input/
├── backend/
│   └── app/
│       ├── main.py          # FastAPI 应用工厂 + 路由
│       ├── config.py         # 配置管理 (get_settings)
│       ├── schemas.py        # Pydantic 数据模型
│       └── services/
│           ├── rewrite.py    # 文本润色服务 (LLM + 本地降级)
│           └── asr.py        # 语音识别服务 (多 Provider)
├── frontend/
│   └── src/
│       ├── main.jsx          # 单文件 React 应用 (1018 行)
│       ├── styles.css
│       ├── rewriteCache.js   # 润色结果缓存
│       └── apiError.js       # 错误处理
└── package.json / README
```

### 1.3 边界确认

- **后端**: FastAPI 单服务，暴露 REST + SSE + WebSocket 三种接口 [事实, `backend/app/main.py:103-241`]
- **前端**: 纯 React 单页应用，无构建工具链 (直接 `<script>` 引入或 Vite 轻量打包) [事实, `frontend/src/main.jsx`]
- **外部依赖**: 百度 ASR、阿里云 ASR (DashScope)、OpenAI 兼容 LLM、浏览器 Web Speech API [事实, `backend/app/services/asr.py:1-517`]

---

## 第 2 步: 还原产品/业务闭环

### 2.1 核心用户旅程

```
用户输入文本 ──▶ 选择润色场景 ──▶ AI/本地润色 ──▶ 查看结果
                                    │
用户语音输入 ──▶ ASR 转写 ──▶ 文本填入 ──▶ 润色 ──▶ 输出
                    │
              实时流式 ASR (WebSocket)
```

### 2.2 业务闭环分析

[事实] 5 个润色场景: auto (自动)、business (商务)、kaomoji (颜文字)、classical (文言文)、emoji (表情) [`backend/app/services/rewrite.py:31-258`]

[事实] 3 种 ASR 模式:
1. 文件上传识别 (`/api/asr`)
2. 流式识别 (`/api/asr/stream`, SSE)
3. 实时识别 (`/ws/asr/realtime`, WebSocket) [`backend/app/main.py:103-241`]

[推断] 产品定位为**轻量级个人写作助手**，强调"语音输入 + AI 润色"的组合能力，而非专业级 ASR 平台。

### 2.3 商业化潜力

[假设] 适合作为 SaaS 工具的一个功能模块嵌入更大产品，独立商业化价值有限 (功能较为单一)。

---

## 第 3 步: 还原技术架构

### 3.1 架构总览

```
┌─────────────────────────────────────────────┐
│  Frontend (React SPA)                        │
│  ┌──────────┐ ┌──────────┐ ┌──────────────┐ │
│  │ 文本润色  │ │ 语音录入  │ │ 设置管理     │ │
│  │ (5场景)  │ │ (WS/SSE) │ │ (localStorage)│ │
│  └────┬─────┘ └────┬─────┘ └──────┬───────┘ │
└───────┼────────────┼──────────────┼─────────┘
        │            │              │
        ▼            ▼              ▼
┌─────────────────────────────────────────────┐
│  Backend (FastAPI)                           │
│  ┌──────────┐ ┌──────────┐ ┌──────────────┐ │
│  │ Rewrite  │ │   ASR    │ │   Config     │ │
│  │ Service  │ │ Service  │ │  (per-req)   │ │
│  └────┬─────┘ └────┬─────┘ └──────────────┘ │
└───────┼────────────┼─────────────────────────┘
        │            │
        ▼            ▼
   ┌─────────┐  ┌─────────────────────┐
   │   LLM   │  │  ASR Providers      │
   │(urllib) │  │ ├─ Baidu (token+base64)│
   └─────────┘  │ ├─ Aliyun (OpenAI-comp)│
                │ └─ Xunfei (STUB!)     │
                └─────────────────────┘
```

### 3.2 关键技术决策

**[事实] 润色服务双路径设计** (`backend/app/services/rewrite.py:31-258`):
- `_has_llm()` 检查是否有 LLM 配置
- 有 LLM: 调用 OpenAI 兼容接口 (通过 `urllib.request`, 非异步)
- 无 LLM: `_local_rewrite()` 本地降级, 包含 `_remove_fillers`、`_business_tone`、`_classical_tone` 等规则函数
- `_split_text()` 处理长文本分片

**[事实] ASR Provider 链式设计** (`backend/app/services/asr.py:1-517`):
- `BaiduAsrProvider`: token 获取 + base64 上传
- `AliyunAsrProvider`: OpenAI 兼容接口, 支持 stream + realtime
- `AliyunRealtimeAsrSession`: WebSocket 连接 DashScope realtime API
- `XunfeiAsrProvider`: **STUB — 直接 raise 错误** [事实, 行号见代码]

**[事实] 前端单文件架构** (`frontend/src/main.jsx:1-1018`):
- 1018 行单文件 React 应用
- 设置存储在 `localStorage` (`yurun-ai-settings`)
- 浏览器 `SpeechRecognition` 作为 ASR 降级方案
- 实时 WebSocket ASR 使用 PCM 编码
- SSE 流读取实现
- `rewriteCache` 做润色结果去重

### 3.3 数据流

[事实] API Key 管理方式: 前端将 API Key 存储在 `localStorage`，每次请求通过 LLM/ASR config payload 发送到后端。后端不做密钥持久化。

---

## 第 4 步: 工程质量评分 (1-5)

| 维度 | 评分 | 理由 |
|------|------|------|
| 产品完整度 | 3 | 功能闭环完整 (语音→文本→润色→输出)，但缺少用户系统、持久化、历史记录 |
| 架构设计 | 3 | Provider 链 + 双路径润色设计合理；但前端单文件 1018 行可维护性差 |
| 工程质量 | 2 | 无测试 (仅 rewriteCache/apiError 有 .test.mjs)、无 CI、Xunfei STUB 未实现、urllib 同步调用阻塞异步事件循环 |
| 可复用性 | 3 | RewriteService 本地降级逻辑、ASR Provider 链模式可复用 |
| 商业化 | 2 | 无认证、无计费、API Key 在前端 localStorage (安全隐患) |

**综合评分: 2.6/5**

### 4.1 关键工程问题

**[事实] 严重: XunfeiAsrProvider 是 STUB** — 直接 `raise` 错误，未实现，但仍在 Provider 链中暴露 [`backend/app/services/asr.py`]。

**[事实] 严重: API Key 存储在前端 localStorage** — 密钥暴露在浏览器端，任何 XSS 都可窃取 [`frontend/src/main.jsx`]。

**[事实] 中等: LLM 调用使用 urllib.request (同步)** — 在 FastAPI 异步框架中使用同步 HTTP 调用，会阻塞事件循环 [`backend/app/services/rewrite.py`]。

**[事实] 中等: 前端单文件 1018 行** — 所有逻辑 (UI + 状态 + 网络 + WS + SSE + 缓存) 集中在 `main.jsx`，可维护性差 [`frontend/src/main.jsx`]。

**[推断] 低: 无用户认证系统** — 未发现 auth 中间件或用户模型，所有接口裸露。

---

## 第 5 步: 优缺点与可复用性评估

### 5.1 优点

1. **[事实] 润色服务本地降级设计优秀** — `_local_rewrite()` 在无 LLM 时仍能提供基础服务 (去口头禅、商务语气、文言文转换)，保证了可用性 [`rewrite.py:31-258`]
2. **[事实] ASR Provider 链式架构** — 多 Provider 可切换，Baidu/Aliyun 各自封装，新增 Provider 只需实现接口 [`asr.py`]
3. **[事实] 多模态 ASR 支持** — 文件上传、SSE 流式、WebSocket 实时三种模式覆盖了不同使用场景
4. **[事实] 前端浏览器 SpeechRecognition 降级** — 在无后端 ASR 时仍可用浏览器原生能力 [`main.jsx`]

### 5.2 缺点

1. **[事实] 安全: API Key 在前端 localStorage** — 严重安全隐患
2. **[事实] 未完成: Xunfei ASR 是 STUB** — 占位代码未实现
3. **[事实] 同步阻塞: urllib.request 在异步框架中** — 应使用 `httpx` 或 `aiohttp`
4. **[事实] 前端单体: 1018 行单文件** — 缺乏组件拆分
5. **[推断] 无持久化: 无数据库** — 无历史记录、无用户数据

### 5.3 可复用资产

| 资产 | 可复用性 | 说明 |
|------|----------|------|
| `RewriteService` 本地降级逻辑 | 高 | 5 场景的规则函数 (`_remove_fillers`, `_business_tone`, `_classical_tone`) 可独立使用 |
| ASR Provider 链模式 | 高 | Provider 接口 + 链式选择模式可复用于任何多供应商场景 |
| `AliyunRealtimeAsrSession` | 中 | WebSocket 实时 ASR 封装可复用，但与 DashScope 强耦合 |
| `rewriteCache` 去重逻辑 | 中 | 简单有效的缓存模式 |
| 前端 SSE/WS 读取实现 | 中 | 可复用的流式读取代码片段 |

### 5.4 不可复用部分

- 前端 `main.jsx` 整体 (过度耦合, 需重构)
- `BaiduAsrProvider` (与百度 API 强耦合, 百度 API 已过时)
- 配置管理 (per-request payload 模式不适合生产)

---

## 第 6 步: 提取学习内容

### 6.1 架构模式学习

**Provider 链 + 双路径降级**
```
请求 → has_provider? ──是──▶ provider.execute()
                │
                否
                ▼
          local_fallback()  ← 规则/模板兜底
```
- 学习点: 对外部依赖 (LLM/ASR) 始终设计本地降级路径，保证服务可用性

**多模态接口设计**
- REST (简单请求) + SSE (服务端流式推送) + WebSocket (双向实时)
- 学习点: 根据数据流方向和实时性需求选择不同的传输协议

### 6.2 反模式学习

1. **异步框架中的同步调用** — `urllib.request` 在 FastAPI 中阻塞事件循环，应使用 `httpx.AsyncClient`
2. **密钥前端存储** — API Key 不应存储在 localStorage，应后端代理
3. **STUB 代码留在生产链路** — 未实现的 Provider 应从链路中移除或明确标注禁用
4. **单文件膨胀** — 1018 行应拆分为组件/hooks/services

### 6.3 可复用代码片段

**润色服务降级模式** (伪代码):
```python
def rewrite(text, scene, config):
    if _has_llm(config):
        try:
            return _llm_rewrite(text, scene, config)
        except Exception:
            pass
    return _local_rewrite(text, scene)  # 规则兜底
```

**ASR Provider 接口** (伪代码):
```python
class AsrProvider(ABC):
    @abstractmethod
    async def transcribe(self, audio: bytes) -> str: ...

class AsrService:
    def __init__(self, providers: list[AsrProvider]):
        self._providers = providers
    async def transcribe(self, audio):
        for p in self._providers:
            try:
                return await p.transcribe(audio)
            except Exception:
                continue
        raise AsrError("all providers failed")
```

---

## YAML 摘要

```yaml
project: voice_input
one_line_judgment: 轻量级语音输入+AI文本润色Web应用，功能闭环但工程化不足，存在安全隐患
product_type: AI写作辅助工具 (语音输入+文本润色)
target_users: 需要语音速记和文本润色的个人用户
core_loop: 语音输入→ASR转写→选场景润色→输出结果
architecture_style: 前后端分离 (FastAPI + React SPA)，Provider链+双路径降级
stack:
  - FastAPI (Python)
  - React (单文件SPA)
  - 百度ASR / 阿里云DashScope ASR
  - OpenAI兼容LLM (urllib同步调用)
  - localStorage (前端设置存储)
strongest_patterns:
  - 润色服务本地降级 (5场景规则函数)
  - ASR Provider链式架构 (多供应商可切换)
  - 多模态接口 (REST+SSE+WebSocket)
main_risks:
  - 严重: API Key存储在前端localStorage (安全隐患)
  - 严重: XunfeiAsrProvider是STUB未实现
  - 中等: urllib同步调用阻塞异步事件循环
  - 中等: 前端1018行单文件可维护性差
  - 低: 无用户认证/无持久化
business_scenarios:
  - 个人语音速记+润色
  - 商务文案快速生成
  - 文言文/颜文字风格转换
reusable_assets:
  - RewriteService本地降级逻辑 (高)
  - ASR Provider链模式 (高)
  - AliyunRealtimeAsrSession WebSocket封装 (中)
  - rewriteCache去重逻辑 (中)
  - 前端SSE/WS读取实现 (中)
non_reusable_parts:
  - main.jsx整体 (过度耦合需重构)
  - BaiduAsrProvider (API过时)
  - per-request配置payload模式 (不适合生产)
scores:
  product: 3
  architecture: 3
  engineering: 2
  reuse: 3
  commercialization: 2
evidence:
  - "[事实] 5个润色场景: rewrite.py:31-258"
  - "[事实] 3种ASR模式: main.py:103-241"
  - "[事实] XunfeiAsrProvider是STUB: asr.py"
  - "[事实] API Key在localStorage: main.jsx"
  - "[事实] urllib同步调用: rewrite.py"
  - "[事实] 前端1018行单文件: main.jsx:1-1018"
  - "[推断] 无用户认证系统"
  - "[假设] 独立商业化价值有限"
confidence: high
```
