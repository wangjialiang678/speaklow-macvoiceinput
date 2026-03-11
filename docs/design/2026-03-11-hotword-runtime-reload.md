# 热词表运行时重载

日期: 2026-03-11
状态: 设计中

## 背景

热词表 (`hotwords.txt`) 当前在启动时加载一次，运行期间无法更新。两种 ASR 模式各自独立加载：

- **Streaming 模式**: Go bridge `initHotwords()` 读文件 → 全局变量 `qwen3Hotwords` → 每次 WebSocket session 使用
- **Batch 模式**: Swift `DashScopeClient.init()` 读 bundle 文件 → `corpusText` 属性 → 每次 REST 请求使用

热词更新频率低，但需要一种显式触发机制，避免重启 app。

## 设计目标

1. **显式触发**: 不自动重载，由用户/脚本主动触发
2. **双模式通用**: 一条命令同时刷新 streaming 和 batch 两种模式的热词
3. **容错**: batch 模式下 Go bridge 未运行时不影响 Swift 侧 reload
4. **热词源统一**: 两端读同一份用户可编辑文件 `~/.config/speaklow/hotwords.txt`

## 现状问题

| 组件 | 热词源文件 | 问题 |
|------|-----------|------|
| Go bridge | `Contents/Resources/hotwords.txt` (bundle) | 编译时固化，运行时不可改 |
| Swift DashScopeClient | `Bundle.main` 内 `hotwords.txt` | 同上 |
| HotwordEditor | `~/.config/speaklow/hotwords.txt` | 编辑后 ASR 不会使用新内容 |

三者断裂：HotwordEditor 编辑的文件和 ASR 实际使用的文件不是同一份。

## 方案

### 1. 统一热词源文件

优先级链（两端一致）：
1. 环境变量 `HOTWORDS_FILE`（覆盖一切）
2. `~/.config/speaklow/hotwords.txt`（用户可编辑）
3. bundle `Contents/Resources/hotwords.txt`（初始模板）

首次启动时 `HotwordManager.ensureMigrated()` 已会将 bundle 文件复制到用户目录。

### 2. Go bridge 改动

**文件**: `asr-bridge/hotword.go`

- `findHotwordsFile()` 新增 `~/.config/speaklow/hotwords.txt` 候选路径（最高优先级）
- `reloadHotwords()` 函数重读文件并更新 `qwen3Hotwords`（已实现）

**文件**: `asr-bridge/main.go`

- `POST /v1/reload-hotwords` → 调用 `reloadHotwords()`，返回 `{"status":"ok","words":N}`（已实现）

### 3. Swift 侧改动

**文件**: `Sources/DashScopeClient.swift`

- `corpusText` 从 `let` 改为 `var`
- `loadCorpusText()` 改为优先读 `~/.config/speaklow/hotwords.txt`，fallback 到 bundle
- 新增 `reloadCorpusText()` 公开方法

**文件**: `Sources/AppDelegate.swift` 或 `AppState.swift`

- 监听 `DistributedNotification` `"com.speaklow.reloadHotwords"`
- 收到通知后调用 `DashScopeClient.shared.reloadCorpusText()`

### 4. CLI 触发脚本

一条命令同时触发两端 reload：

```bash
#!/bin/bash
# speaklow-reload-hotwords: 重载热词表（streaming + batch 双模式）

BRIDGE_URL="http://localhost:18089"

# 1. 尝试通知 Go bridge（streaming 模式，bridge 可能未运行）
if curl -sf -X POST "$BRIDGE_URL/v1/reload-hotwords" -o /tmp/speaklow-reload.json 2>/dev/null; then
    words=$(python3 -c "import json; print(json.load(open('/tmp/speaklow-reload.json'))['words'])" 2>/dev/null)
    echo "✓ Bridge 热词已重载 ($words 个)"
    rm -f /tmp/speaklow-reload.json
else
    echo "- Bridge 未运行，跳过"
fi

# 2. 通知 Swift app（通过 macOS 分布式通知，无论什么模式都生效）
# DistributedNotificationCenter 通知由 osascript 触发
osascript -e 'tell application "System Events" to do shell script "
/usr/bin/python3 -c \"
import Foundation
nc = Foundation.NSDistributedNotificationCenter.defaultCenter()
nc.postNotificationName_object_userInfo_deliverImmediately_(
    'com.speaklow.reloadHotwords', None, None, True)
\"
"' 2>/dev/null && echo "✓ App 热词已通知重载" || echo "- App 通知发送失败"
```

实际实现时简化为 Python one-liner 调用 `NSDistributedNotificationCenter`。

### 5. 数据流

```
用户编辑 ~/.config/speaklow/hotwords.txt
  │
  ├─ CLI: speaklow-reload-hotwords
  │   ├─ curl POST /v1/reload-hotwords → Go bridge 重读文件 → qwen3Hotwords 更新
  │   └─ DistributedNotification → Swift app 收到 → DashScopeClient.reloadCorpusText()
  │
  └─ 或 HotwordEditor 保存按钮
      ├─ 调 bridge /v1/reload-hotwords（如果 bridge 在运行）
      └─ 直接调 DashScopeClient.shared.reloadCorpusText()
```

### 6. 错误处理

| 场景 | 行为 |
|------|------|
| 热词文件不存在 | reload 返回错误，保留旧值 |
| 热词文件解析失败（空文件） | corpus 设为空字符串，ASR 无热词辅助但不崩溃 |
| Bridge 未运行（batch 模式） | CLI 跳过 bridge 调用，只发通知 |
| Swift app 未运行 | 通知无接收者，静默忽略 |

## 影响范围

| 文件 | 改动类型 |
|------|---------|
| `asr-bridge/hotword.go` | 修改 `findHotwordsFile()` 优先级 + `reloadHotwords()`（已完成） |
| `asr-bridge/main.go` | 注册 `/v1/reload-hotwords`（已完成） |
| `asr-bridge/hotword_test.go` | 新增：reload 单元测试 |
| `Sources/DashScopeClient.swift` | `corpusText` var + `reloadCorpusText()` + 文件优先级 |
| `Sources/AppDelegate.swift` | 监听 DistributedNotification |
| `scripts/speaklow-reload-hotwords` | 新增：CLI 脚本 |

## 不做的事

- 不做热词文件 watch（fsnotify）— 显式触发更可靠
- 不做 bridge 和 Swift 之间的热词同步协议 — 各自从文件读，源文件相同即一致
- 不在 reload 时验证热词内容语义 — 只做格式解析
