# guyuInput 项目审计报告

> 一句话判断：guyuInput 是一个架构清晰的 Windows 桌面语音输入法，其"多供应商 ASR 调度 + 在线/离线自动降级 + 两级文本后处理"链路设计完整，但零测试覆盖和明文存储 API 凭证是明显短板。

---

## 一、项目边界确认

### 1.1 项目定位（事实）

guyuInput 是一个 Windows 智能语音输入法。用户按全局热键说话，再按一次停止，ASR 识别后经词典校正和可选 AI 润色，文字自动注入到任意应用的当前光标位置。

- README：`/Users/allure/Desktop/七牛云项目/guyuInput/README.md` 第 1-3 行
- 入口：`/Users/allure/Desktop/七牛云项目/guyuInput/main.py` 第 1-3 行

### 1.2 目录结构（事实）

```
guyuInput/
├── main.py                    # 入口，连线 API ↔ UI（124 行）
├── backend/                   # 后端核心
│   ├── app.py                 # API 类，Qt 信号驱动（401 行）
│   ├── audio.py               # 音频采集 (sounddevice)
│   ├── hotkey.py              # 全局快捷键 (keyboard 库)（143 行）
│   ├── input.py               # Win32 文本注入（181 行）
│   ├── tray.py                # 系统托盘 (pystray)
│   ├── config.py              # SQLite 配置管理（80 行）
│   ├── logger.py              # 日志初始化
│   ├── asr/                   # ASR 引擎
│   │   ├── base.py            # 抽象基类 + ASRMode/ASRResult（48 行）
│   │   ├── dispatcher.py      # 调度器 + 自动降级（173 行）
│   │   ├── sherpa_onnx_engine.py  # 离线引擎 (sherpa-onnx)
│   │   ├── xunfei.py          # 讯飞实时语音转写
│   │   ├── ali.py             # 阿里云 NLS
│   │   ├── doubao.py          # 豆包语音识别
│   │   └── minimax.py         # MiniMax ASR
│   ├── dictionary/            # 词典校正
│   │   ├── corrector.py       # FlashText 词典校正引擎
│   │   └── zh_dict.json       # 内置中文常用词库
│   └── polish/                # AI 润色
│       ├── base.py            # 抽象接口 + PolishMode 枚举
│       ├── dispatcher.py      # 润色调度（失败降级返回原文）（37 行）
│       ├── openai.py          # OpenAI / 兼容 API 润色
│       ├── doubao.py          # 豆包 (火山引擎 ark) 润色
│       └── prompts.py         # 润色 Prompt 模板
├── ui/                        # PySide6 UI
│   ├── main_window.py         # 主窗口控制器 + 视图切换
│   ├── idle_widget.py         # 空闲态：圆形麦克风图标
│   ├── recording_widget.py    # 录音态：文字回显 + 取消/确认
│   ├── error_widget.py        # 错误提示条
│   ├── guide_page.py          # 首次引导页
│   ├── settings_page.py       # 设置页
│   └── icons.py               # 矢量图标绘制
├── pyproject.toml             # 项目元数据 + ruff/black 配置
├── requirements.txt           # 依赖（10 行）
└── .gitignore                 # 覆盖 config.db、models/、*.log
```

- 总代码量：4530 行 Python（`wc -l` 统计）
- 技术文档：`AI文本润色技术文档.md`、`Qt方案需求分析.md`、`sherpa-onnx离线语音识别技术文档.md`

### 1.3 技术栈（事实）

| 层 | 技术 | 来源 |
|---|---|---|
| UI 框架 | PySide6 (Qt 6) | `requirements.txt` 第 2 行 |
| 音频采集 | sounddevice + numpy | `requirements.txt` 第 5-6 行 |
| 在线 ASR | 讯飞/阿里/豆包/MiniMax WebSocket | `backend/asr/` 目录 |
| 离线 ASR | sherpa-onnx + SenseVoice INT8 | `requirements.txt` 第 16 行 |
| 词典校正 | FlashText | `requirements.txt` 第 19 行 |
| AI 润色 | OpenAI / 豆包 / 兼容 API | `backend/polish/` 目录 |
| 文本注入 | Win32 API (ctypes) | `backend/input.py` |
| 快捷键 | keyboard 库 | `requirements.txt` 第 13 行 |
| 系统托盘 | pystray | README 第 30 行（注：requirements.txt 未列出，推断为间接依赖） |
| 配置存储 | SQLite | `backend/config.py` |

---

## 二、用户/产品回路还原

### 2.1 目标用户（事实）

Windows 用户，希望在任意应用中通过语音输入文字，而非手动打字。

### 2.2 核心产品回路（事实）

```
按热键(Ctrl+Alt+V) → 开始录音 → ASR 流式识别(在线/离线)
→ 再按热键 → 停止录音 → 词典校正(<1ms) → [可选] AI 润色
→ 剪贴板写入 + 模拟 Ctrl+V → 文本注入到当前光标位置
```

- 热键切换：`main.py` 第 110 行 `register_toggle_callback(on_toggle=self._on_hotkey_toggle)`
- 录音启动：`app.py` 第 251-305 行 `start_recording()` — 前置凭证检查 → 引擎启动 → 音频采集
- ASR 识别：`app.py` 第 349-350 行 `_on_audio_data()` → `dispatcher.feed_audio()`
- 停止注入：`app.py` 第 307-343 行 `stop_recording()` — 词典校正 → AI 润色 → 热键抑制 → 文本注入
- 文本注入：`input.py` 第 67-84 行 `inject_text()` → 剪贴板写入 → 模拟 Ctrl+V → 恢复原剪贴板

### 2.3 降级回路（事实）

```
AUTO 模式：在线引擎启动 → 在线 ASR 错误 → 自动切换离线引擎 → 继续识别
```

- `dispatcher.py` 第 149-165 行 `_on_online_error()`：AUTO 模式下在线引擎出错时自动降级到离线引擎，不向上传播错误

---

## 三、技术架构还原

### 3.1 整体架构（事实）

```
┌──────────────────────────────────────────────────────┐
│                    UI Layer (PySide6)                  │
│  ┌──────────┐  ┌──────────┐  ┌────────────────────┐  │
│  │ IdleWidget│  │Recording │  │ SettingsPage       │  │
│  │ (麦克风)  │  │ Widget   │  │ (API凭证/设备/热键) │  │
│  └────┬─────┘  └────┬─────┘  └─────────┬──────────┘  │
│       │ Qt Signals   │                   │             │
│  ┌────┴──────────────┴───────────────────┴──────────┐ │
│  │              MainWindow (视图切换)                 │ │
│  └──────────────────────┬────────────────────────────┘ │
└─────────────────────────┼────────────────────────────┘
                          │ Qt Signals (start/stop/config)
                          ▼
┌──────────────────────────────────────────────────────┐
│              API Layer (backend/app.py)                │
│  ┌──────────────────────────────────────────────────┐ │
│  │  API(QObject) — Qt 信号驱动的中央编排器           │ │
│  │  recording_started/stopped/error, asr_partial/    │ │
│  │  final/error, volume_changed, config_loaded...    │ │
│  └──┬──────┬──────┬──────┬──────┬───────────────────┘ │
│     │      │      │      │      │                     │
│  ┌──┴──┐┌──┴──┐┌──┴──┐┌──┴──┐┌──┴────────────────┐  │
│  │Audio││Hotkey││Input││Config││  ASRDispatcher    │  │
│  │Capt ││Mgr   ││ject ││Mgr  ││  ┌──────────────┐ │  │
│  └─────┘└─────┘└─────┘└─────┘│  │Online Engines│ │  │
│                                │  │xunfei/ali/   │ │  │
│                                │  │doubao/minimax│ │  │
│                                │  └──────┬───────┘ │  │
│                                │  ┌──────┴───────┐ │  │
│                                │  │Offline Engine│ │  │
│                                │  │sherpa-onnx   │ │  │
│                                │  └──────────────┘ │  │
│                                └────────────────────┘  │
│  ┌─────────────┐  ┌────────────────────────────────┐  │
│  │DictCorrector│  │  PolishDispatcher              │  │
│  │(FlashText)  │  │  (OpenAI/Doubao, 失败返回原文)  │  │
│  └─────────────┘  └────────────────────────────────┘  │
└──────────────────────────────────────────────────────┘
```

### 3.2 核心架构模式：Qt 信号驱动的中央编排器（事实）

`API` 类继承 `QObject`，定义 14 个 Qt 信号（`app.py` 第 35-49 行），作为 UI 与后端的唯一通信通道：

- UI → API：通过信号 `start_recording_signal`、`stop_recording_signal`、`config_signal` 等
- API → UI：通过信号 `recording_started`、`asr_partial`、`asr_final`、`volume_changed` 等

`main.py` 第 51-75 行完成所有信号连线，职责清晰。

### 3.3 ASR 调度器：三模式 + 自动降级（事实）

`dispatcher.py` 第 21-173 行 `ASRDispatcher` 支持三种模式（`base.py` 第 12-15 行 `ASRMode` 枚举）：

1. **ONLINE**：仅使用指定在线供应商，失败报错
2. **OFFLINE**：仅使用 sherpa-onnx 离线引擎
3. **AUTO**（默认）：优先在线，失败自动降级到离线

自动降级逻辑（`dispatcher.py` 第 149-165 行）：
```python
def _on_online_error(self, err: str):
    if self.mode == ASRMode.AUTO and not self._online_failed:
        self._online_failed = True
        self._current_engine.stop()
        if self._is_recording:
            self._start_offline()  # 自动降级，不向上传播错误
            return
    self._on_error(err)  # ONLINE 模式或降级失败才报错
```

pending audio 机制（`dispatcher.py` 第 87-94/167-172 行）：引擎未就绪时音频暂存 `_pending_audio`，引擎就绪后 `_flush_pending_audio()` 批量送入，避免丢帧。

### 3.4 两级文本后处理（事实）

`app.py` 第 319-337 行 `stop_recording()`：

1. **一级：词典校正**（默认开启，<1ms）
   - `DictionaryCorrector` 基于 FlashText 算法
   - 内置 `zh_dict.json` 中文常用词库
   - 可配置启用/禁用和自定义词典 section

2. **二级：AI 润色**（默认关闭，需配置 API）
   - `PolishDispatcher` 支持 3 种力度：`punctuation_only`（仅标点）、`moderate`（适度润色）、`deep`（深度润色）
   - 支持 OpenAI / 豆包 / 兼容 API（DeepSeek、通义千问等）
   - **失败降级**：`polish/dispatcher.py` 第 23-36 行，任何异常返回原文，不影响输入
   - 过短文本跳过润色（`app.py` 第 329 行 `len(text) >= 3`）

### 3.5 Win32 文本注入（事实）

`input.py` 第 38-181 行 `TextInjector`：

- **策略**：剪贴板写入 + 模拟 Ctrl+V（兼容性最广）
- **剪贴板备份/恢复**：第 77/84 行，注入前保存原剪贴板内容，注入后恢复
- **x64 指针修复**：第 46-65 行，显式设置 `GlobalAlloc.restype = ctypes.c_void_p` 等，解决 64 位 Python 下指针截断问题
- **SendInput → keybd_event 降级**：第 165-180 行，SendInput 被 UIPI 阻止时回退到 keybd_event
- **重试机制**：第 113-118 行，OpenClipboard 失败时重试 3 次（其他程序占用剪贴板时）

### 3.6 全局热键 + 注入抑制（事实）

`hotkey.py` 第 15-143 行 `HotkeyManager`：

- **单按切换模式**：第 102-105 行，每次按下热键切换录音状态
- **注入抑制**：第 73-79 行 `suppress_temporarily(0.5)`，文本注入期间抑制钩子 0.5 秒，避免模拟的 Ctrl+V 被误判为热键触发
- **修饰键匹配**：第 119-131 行，支持 left/right ctrl/alt/shift/win

---

## 四、工程质量评估

### 4.1 评分总览

| 维度 | 评分 | 依据 |
|---|---|---|
| 架构设计 | 4/5 | Qt 信号驱动 + ASR 调度器 + 两级后处理，职责清晰 |
| 代码质量 | 4/5 | x64 指针修复、SendInput 降级、剪贴板恢复等细节考究 |
| 测试覆盖 | 1/5 | 零测试文件 |
| 安全性 | 3/5 | API 凭证明文存储 SQLite，但 .gitignore 覆盖 config.db |
| 可维护性 | 4/5 | 模块化清晰，ABC 抽象基类，调度器模式统一 |
| 文档质量 | 4/5 | README 完整 + 3 份技术文档，但缺 API 文档 |
| 可复现性 | 3/5 | 离线模型需单独下载 240MB，在线模式需配置凭证 |
| **综合** | **3.3/5** | |

### 4.2 架构设计（4/5）——证据

**正面：**
- Qt 信号驱动架构使 UI 与后端解耦（`app.py` 第 29-49 行 14 个信号定义）——事实
- ASR 引擎抽象基类（`base.py` 第 25-47 行 `ASREngine(ABC)`），4 个在线引擎 + 1 个离线引擎统一接口——事实
- ASR 调度器三模式设计（ONLINE/OFFLINE/AUTO）+ 自动降级（`dispatcher.py` 第 149-165 行）——事实
- pending audio 机制避免引擎切换期间丢帧（`dispatcher.py` 第 87-94/167-172 行）——事实
- 润色调度器失败降级返回原文（`polish/dispatcher.py` 第 23-36 行）——事实

**负面：**
- `app.py` 第 279-281 行 `while not engine.is_ready: time.sleep(0.05)` 在主线程轮询等待模型加载，虽有 `QApplication.processEvents()` 保持 UI 响应，但不是最佳实践——事实
- `dispatcher.py` 第 128 行错误消息提到 "FunASR" 但实际使用 sherpa-onnx，注释过时——事实

### 4.3 代码质量（4/5）——证据

**正面：**
- x64 指针类型修复（`input.py` 第 46-65 行）：显式设置 `restype` 和 `argtypes`，解决 64 位 Python 下 `GlobalAlloc` 返回值被截断为 32 位的问题——事实
- SendInput → keybd_event 降级（`input.py` 第 165-180 行）：UIPI 阻止 SendInput 时自动回退——事实
- 剪贴板备份/恢复（`input.py` 第 77/84 行）：注入前保存原内容，注入后恢复——事实
- OpenClipboard 重试 3 次（`input.py` 第 113-118 行）：其他程序占用剪贴板时的容错——事实
- 热键注入抑制（`hotkey.py` 第 73-79 行）：避免模拟 Ctrl+V 被误判为热键——事实
- 离线引擎异步预加载（`app.py` 第 78 行 `preload_async()`）：避免首次使用卡 UI——事实
- 静音超时自动关闭（`app.py` 第 356-361 行 3 秒 `threading.Timer`）——事实

**负面：**
- `threading.Timer` 回调在非 Qt 线程中 emit 信号（`app.py` 第 368-369 行），虽然 Qt 信号是线程安全的（通过 QueuedConnection），但缺少显式连接类型声明——推断
- `app.py` 第 200 行直接访问 `self.config.conn.execute()`，绕过 ConfigManager 封装——事实

### 4.4 测试覆盖（1/5）——证据

- `find` 搜索结果：零测试文件——事实
- 无 pytest、unittest 或任何测试框架配置——事实
- `pyproject.toml` 仅有 ruff/black 配置，无 pytest 配置——事实

### 4.5 安全性（3/5）——证据

**正面：**
- `.gitignore` 覆盖 `config.db`（第 46 行），凭证文件不进仓库——事实
- `.gitignore` 覆盖 `models/`（第 49 行），大文件不进仓库——事实
- 凭证仅存储在本地 SQLite，不上传任何服务器——事实
- README 第 137 行明确"凭证保存在本地 SQLite 数据库"

**负面（P2 安全隐患）：**
- API 凭证明文存储在 SQLite `config.db`（`config.py` 第 48-54 行 `set()` 直接写入 value，无加密）——事实
- 无 DPAPI 或任何操作系统级密钥保护——推断
- 任何有文件系统访问权限的程序可读取 `~/.guyuInput/config.db` 中的全部 API 凭证——推断

### 4.6 文档质量（4/5）——证据

**正面：**
- README 198 行：功能特性、技术栈、项目结构、安装、使用说明、配置说明、开发指南、开源引用——事实
- 3 份技术文档：`AI文本润色技术文档.md`、`Qt方案需求分析.md`、`sherpa-onnx离线语音识别技术文档.md`——事实
- 开源引用表（README 第 177-187 行）注明许可证——事实
- 原创部分声明（README 第 189-197 行）——事实

**负面：**
- 无 API 文档或代码注释文档——推断
- `dispatcher.py` 第 128 行注释 "FunASR" 过时——事实

---

## 五、优点

1. **ASR 调度器三模式设计**（事实）：ONLINE/OFFLINE/AUTO + 自动降级，用户可选"自动"模式实现无感降级体验

2. **pending audio 机制**（事实）：引擎切换期间音频暂存，就绪后批量送入，避免丢帧

3. **Win32 文本注入细节考究**（事实）：x64 指针修复、SendInput→keybd_event 降级、剪贴板备份/恢复、OpenClipboard 重试

4. **热键注入抑制**（事实）：`suppress_temporarily(0.5)` 避免模拟 Ctrl+V 被全局热键钩子误判

5. **离线引擎异步预加载**（事实）：`preload_async()` 后台加载模型，避免首次使用卡 UI

6. **两级文本后处理**（事实）：FlashText 词典校正（<1ms，默认开启）+ AI 润色（可选，失败降级返回原文），性能与功能分层

7. **Qt 信号驱动架构**（事实）：14 个信号定义清晰的通信协议，UI 与后端完全解耦

8. **ASR 引擎抽象基类**（事实）：`ASREngine(ABC)` 统一 start/feed_audio/stop 接口，4 个在线引擎 + 1 个离线引擎可互换

9. **配置管理完善**（事实）：SQLite 持久化、默认值初始化、get/get_bool/get_int/get_json 多类型访问

10. **开源引用规范**（事实）：注明所有使用的开源项目及许可证，区分原创部分

---

## 六、缺点与风险

### P1 级（需修复）

1. **零测试覆盖**（事实）：无任何测试文件，核心逻辑（调度器降级、文本注入、词典校正）无自动化验证

### P2 级（应改进）

2. **API 凭证明文存储**（事实）：`config.db` 中 API Key/Secret 明文存储，无 DPAPI 或加密保护

3. **主线程轮询等待模型加载**（事实）：`app.py` 第 279-281 行 `while not engine.is_ready: time.sleep(0.05)` 在主线程轮询，虽有 `processEvents()` 但非最佳实践

4. **离线模型需手动下载**（事实）：240MB 模型需用户手动 curl 下载，无自动下载或进度提示

5. **tray.py 依赖未在 requirements.txt 声明**（推断）：README 第 30 行提到 pystray + PIL，但 `requirements.txt` 未列出

### P3 级（可优化）

6. **过时注释**（事实）：`dispatcher.py` 第 128 行 "FunASR" 应为 "sherpa-onnx"

7. **ConfigManager 封装被绕过**（事实）：`app.py` 第 200 行直接访问 `self.config.conn.execute()`

8. **无 CI/CD**（推断）：项目目录下无 CI 配置

9. **无类型检查配置**（推断）：无 mypy.ini 或 pyright 配置，pyproject.toml 仅有 ruff/black

10. **单文件路径硬编码**（推断）：config.db 路径 `~/.guyuInput/config.db` 硬编码在 `config.py` 第 12-14 行

---

## 七、可复用性矩阵

| 模块 | 可复用场景 | 复用成本 | 备注 |
|---|---|---|---|
| ASR 调度器（三模式+自动降级） | 任何多供应商 ASR 应用 | 低 | `dispatcher.py` 模式清晰 |
| ASR 引擎抽象基类 | 任何 ASR 引擎集成 | 低 | `base.py` ABC 接口简洁 |
| Win32 文本注入（剪贴板+Ctrl+V） | 任何 Windows 文本注入需求 | 中 | `input.py` x64 修复+降级+恢复 |
| 热键注入抑制模式 | 任何全局热键+模拟按键共存的场景 | 低 | `hotkey.py` 第 73-79 行 |
| pending audio 机制 | 任何引擎切换期间需保帧的场景 | 低 | `dispatcher.py` 第 87-94 行 |
| 两级文本后处理架构 | 任何 ASR 后处理流水线 | 低 | 词典→AI 分层设计 |
| 润色失败降级模式 | 任何可选 AI 增强功能 | 低 | `polish/dispatcher.py` 返回原文 |
| Qt 信号驱动架构 | 任何 PySide6 桌面应用 | 低 | 信号定义+main.py 连线模式 |
| SQLite 配置管理 | 任何桌面应用配置存储 | 低 | `config.py` 多类型访问 |
| 离线引擎异步预加载 | 任何大模型桌面应用 | 低 | `preload_async()` 模式 |

---

## 八、学习内容提取

### 8.1 架构设计学习

1. **Qt 信号驱动桌面架构**：`QObject` 子类定义信号，`main.py` 集中连线，UI 与后端完全解耦。这比 pywebview JS Bridge 或直接回调更清晰。

2. **ASR 调度器三模式设计**：ONLINE（仅在线）/OFFLINE（仅离线）/AUTO（自动降级）。AUTO 模式下在线出错自动切离线，不向上传播错误，实现无感降级。

3. **pending audio 机制**：引擎未就绪时音频暂存 list，就绪后批量 flush。这解决了引擎初始化期间音频丢失问题。

4. **两级文本后处理分层**：快速确定性校正（FlashText，<1ms）+ 可选 AI 增强（失败降级），性能与功能分层。

### 8.2 Win32 工程学习

5. **x64 指针类型修复**：64 位 Python 下 ctypes 默认 `c_int` 返回值只有 32 位，指针被截断。必须显式设置 `GlobalAlloc.restype = ctypes.c_void_p`。

6. **SendInput → keybd_event 降级**：SendInput 可能被 UIPI（User Interface Privilege Isolation）阻止（如目标窗口是管理员权限），需回退到 keybd_event。

7. **剪贴板备份/恢复**：文本注入前保存原剪贴板内容，注入后恢复。这是用户体验细节——不破坏用户剪贴板。

8. **OpenClipboard 重试**：剪贴板可能被其他程序占用，OpenClipboard 失败时重试 3 次。

### 8.3 热键工程学习

9. **注入抑制**：模拟 Ctrl+V 时全局热键钩子可能捕获到这个按键事件，误判为热键触发。`suppress_temporarily(0.5)` 在注入期间抑制钩子。

10. **left/right 修饰键**：`keyboard.is_pressed('ctrl')` 不检测 right ctrl，需单独检测 `keyboard.is_pressed('right ctrl')`。

---

## 九、YAML 摘要

```yaml
project: guyuInput
type: "Windows 智能语音输入法 (PySide6 桌面应用)"
tech_stack:
  ui: "PySide6 (Qt 6)"
  audio: "sounddevice + numpy"
  asr_online: "讯飞/阿里/豆包/MiniMax WebSocket"
  asr_offline: "sherpa-onnx + SenseVoice INT8"
  dictionary: "FlashText"
  polish: "OpenAI / 豆包 / 兼容 API"
  injection: "Win32 API (ctypes, 剪贴板+Ctrl+V)"
  config: "SQLite (~/.guyuInput/config.db)"
lines_of_code:
  python_total: 4530
  backend_app: 401
  dispatcher: 173
  input: 181
  config: 80
scores:
  architecture: 4
  code_quality: 4
  test_coverage: 1
  security: 3
  maintainability: 4
  documentation: 4
  reproducibility: 3
  overall: 3.3
key_strengths:
  - "ASR 调度器三模式设计（ONLINE/OFFLINE/AUTO）+ 自动降级"
  - "Win32 文本注入细节考究（x64修复/SendInput降级/剪贴板恢复/重试）"
  - "热键注入抑制避免模拟按键误触发"
  - "两级文本后处理（FlashText词典 + AI润色降级）"
  - "Qt 信号驱动架构，UI与后端解耦"
  - "ASR 引擎抽象基类，4在线+1离线统一接口"
  - "pending audio 机制避免引擎切换丢帧"
  - "离线引擎异步预加载避免卡UI"
key_issues:
  - severity: P1
    issue: "零测试覆盖，无任何测试文件"
    location: "整个项目"
  - severity: P2
    issue: "API 凭证明文存储在 SQLite config.db，无加密"
    location: "backend/config.py 第 48-54 行"
  - severity: P2
    issue: "主线程轮询等待模型加载"
    location: "backend/app.py 第 279-281 行"
  - severity: P2
    issue: "离线模型 240MB 需手动下载，无自动下载机制"
    location: "README.md 第 89-98 行"
  - severity: P3
    issue: "过时注释：dispatcher.py 第 128 行 FunASR 应为 sherpa-onnx"
    location: "backend/asr/dispatcher.py 第 128 行"
reusability:
  - module: "ASR 调度器（三模式+自动降级）"
    cost: low
  - module: "Win32 文本注入（剪贴板+Ctrl+V）"
    cost: medium
  - module: "热键注入抑制模式"
    cost: low
  - module: "pending audio 机制"
    cost: low
  - module: "两级文本后处理架构"
    cost: low
  - module: "润色失败降级模式"
    cost: low
  - module: "Qt 信号驱动架构"
    cost: low
  - module: "ASR 引擎抽象基类"
    cost: low
  - module: "SQLite 配置管理"
    cost: low
  - module: "离线引擎异步预加载"
    cost: low
security_findings:
  - severity: P2
    type: "凭证存储"
    detail: "API 凭证明文存储在 SQLite，无 DPAPI 或加密"
    evidence_type: fact
  - severity: pass
    type: "文件忽略"
    detail: ".gitignore 覆盖 config.db、models/、*.log"
    evidence_type: fact
  - severity: pass
    type: "凭证隔离"
    detail: "凭证仅本地存储，不上传服务器"
    evidence_type: fact
evidence_discipline:
  total_findings: 20
  fact: 17
  inference: 3
  hypothesis: 0
```
