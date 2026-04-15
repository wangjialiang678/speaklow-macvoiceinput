# SpeakLow 麦克风问题根因调查

日期：2026-04-15  
范围：只做日志分析、代码静态分析、当前系统状态读取；未运行 SpeakLow App，未修改业务代码。

## 1. 现象模式分析

### 1.1 过去几天实际出现了 4 类失败

| 形态 | 时间段 | 频率 | 直接表现 | 备注 |
|---|---|---:|---|---|
| A. 启动即失败（`2003329396`） | 2026-04-10 13:09-14:13 | `start_fail_final=5` | `Streaming recording start failed` / `麦克风启动失败（MacBook Air麦克风）` | 这是一次真实的 `AVAudioEngine.start()` 失败族 |
| B. Bridge 崩溃循环 + 双实例痕迹 | 2026-04-10 13:09-13:14 | 数百条 | `Bridge 崩溃（exit 1）...`，同一秒内双份 `startRecording()` / `AXIsProcessTrusted()` | 和麦克风链路交织，但不是同一个根因 |
| C. 远端/Bridge WebSocket 失败 | 2026-04-10 14:57-14:58；2026-04-14 09:46 | 少量 | `connect dashscope: EOF` / `Socket is not connected` | 网络/桥接链路问题 |
| D. “2 秒内没有首个有效音频” | 2026-04-14 01:45-01:47、09:44、23:57；2026-04-15 00:25 | `silence_timeout=10` | `麦克风没有声音` / `Silence timeout` | 这是最新仍在复发的问题族 |

### 1.2 各日期统计

从 `/tmp/speaklow-investigation.log` 统计：

| 日期 | Hotkey Down | `2003329396` 最终失败 | Silence Timeout | Streaming Failed | WS Finished |
|---|---:|---:|---:|---:|---:|
| 2026-04-10 | 45 | 5 | 0 | 5 | 26 |
| 2026-04-11 | 29 | 0 | 0 | 0 | 18 |
| 2026-04-12 | 60 | 0 | 0 | 0 | 58 |
| 2026-04-13 | 78 | 0 | 0 | 0 | 73 |
| 2026-04-14 | 54 | 0 | 6 | 1 | 39 |
| 2026-04-15 | 6 | 0 | 4 | 0 | 2 |

结论：

- `4/10` 的主故障是 `2003329396` + bridge/双实例混乱。
- `4/14-4/15` 的主故障已经换成另一类：`AVAudioEngine.start()` 没报错，但 **2 秒内从未进入 recording ready**。
- 最新 commit `8f8b518` 之后，`2026-04-14 23:57:57` 和 `2026-04-15 00:25:20/24/28/32` 仍然连续出现 5 次 silence timeout，说明它没有根治最新问题。

### 1.3 成功和失败的时序差异

成功录音的共同模式：

1. `handleHotkeyDown()`
2. `WS connected`
3. 很快出现 `Sound 'Tink' played`
4. 随后出现 `Streaming partial`
5. `stopStreamingRecording`
6. `WS closed: finished`

失败录音（最新一类）的共同模式：

1. `handleHotkeyDown()`
2. `WS connected`
3. **没有** `Sound 'Tink' played`
4. **没有** `Streaming partial`
5. 约 2 秒后直接 `Silence timeout — stopping recording and showing error`

典型样本：

- 失败：`2026-04-15 00:25:17` 开始，`00:25:18` WS 连上，`00:25:20` silence timeout。
- 成功：`2026-04-14 23:58:01` 开始，`23:58:02` WS 连上，`23:58:03` 出现 `Tink`，随后连续 partial，`23:58:19` 正常 finished。

这说明最新问题不是 “WS 根本没连上”，而是 **录音链路没有在 2 秒内拿到首个可用音频**。

## 2. 真正的根因

### 2.1 先说结论

这批问题里，**没有证据支持“过去一周只有一个单一硬件根因”**。当前材料能证实的是：

1. `4/10` 的 `2003329396` 是一类独立的、真实的麦克风启动失败事件。
2. 更关键、一直没有被根治的根因是：  
   **SpeakLow 没有“实际录音设备已绑定且已有可用音频”的确认机制。**

这不是一句抽象话，它具体表现为两条代码级事实：

- 代码只保存“期望设备”，**不校验实际绑定结果**。
- 代码在拿到首个有效音频之前，**就把录音/流式 session 当成已经开始**。

于是任何 “前 2 秒没有首个有效 buffer” 的事件，不管真实物理原因是：

- 用户没说话，
- 蓝牙设备静默，
- 选中设备失效后悄悄回退到默认设备，
- `AudioUnitSetProperty(CurrentDevice)` 没生效，

都会在产品层被展开成一串不同表象：

- `silence timeout`
- `0ms < 200ms，丢弃`
- WebSocket 泄漏 / stale callback
- “app 卡住”
- 错误的设备提示

**真正没被修掉的根因，是“麦克风获取成功”的判断模型本身是假的。**

### 2.2 这不是猜测，而是代码事实

#### 根因 1：设备选择只有“意图”，没有“验证”

`AppState` 从 `UserDefaults` 读出 `selected_microphone_id`，当前值是：

```text
selected_microphone_id = BuiltInMicrophoneDevice
```

当前系统真实输入设备状态：

```text
default input = AC-33-28-F0-AB-73:input (HUAWEI FreeBuds 6i)
built-in input = BuiltInMicrophoneDevice (MacBook Air麦克风)
```

代码路径：

- `AppState.resolvedRecordingDeviceUID()` 只是把存储值原样返回，没有做合法性回退或一致性校验。[`speaklow-app/Sources/AppState.swift:439-444`]
- `AudioRecorder.startRecording()` 尝试把 `CurrentDevice` 设为目标设备，但：
  - `AudioUnitSetProperty(...)` 的返回值被直接忽略；[`speaklow-app/Sources/AudioRecorder.swift:263-275`]
  - 没有 read-back 当前实际设备；
  - 如果 `deviceID(forUID:)` 找不到，代码静默跳过，直接继续走默认输入设备；[`speaklow-app/Sources/AudioRecorder.swift:263-275`]
- 错误提示也不基于“实际绑定设备”：
  - `showMicError()` 用的是传进来的“期望设备 UID”，不是 engine 当前设备。[`speaklow-app/Sources/AppState.swift:455-477`]
  - silence timeout 用的是“当前默认输入设备 UID”，也不是 engine 当前设备。[`speaklow-app/Sources/AppState.swift:880-887`]

所以整个系统里根本不存在一个可信的 “我现在到底录的是哪只麦克风” 状态。

#### 根因 2：session 在 microphone ready 之前就已经被视为开始

代码路径：

- `startRecording()` 一进来就先 `isRecording = true`。[`speaklow-app/Sources/AppState.swift:579`]
- streaming 路径在 `_beginRecordingAfterHealthCheck()` 里先创建 `StreamingTranscriptionService`，马上 `streaming.start()` 打开 WebSocket。[`speaklow-app/Sources/AppState.swift:820-840`]
- 真正启动 `audioRecorder.startRecording(...)` 是后面另一段异步后台线程逻辑。[`speaklow-app/Sources/AppState.swift:900-904`]
- `recordingStartTime` 不是在热键按下时设置，而是在 `onRecordingReady` 里，也就是 **首个非静音 buffer 到达之后** 才设置。[`speaklow-app/Sources/AppState.swift:845-850`]
- 停止时如果 `recordingStartTime == nil`，就会被判成 `0ms < 200ms` 丢弃。[`speaklow-app/Sources/AppState.swift:1051-1068`]

这意味着：

- “按下热键” 不等于 “麦克风真的工作了”
- “WS connected” 不等于 “已经拿到音频”
- “isRecording=true” 不等于 “正在录到声音”

所以一旦前 2 秒没有首个有效 buffer，日志就会出现非常迷惑的二次症状：

- 明明按了几秒，日志却写 `0ms`
- WS 已经连上，但录音实际没 ready
- 清理不彻底时看起来像“卡住”

### 2.3 `4/10` 的 `2003329396` 是另一条、已被识别但和最新问题不同的故障链

`2026-04-10 13:09:11/13:09:13/14:13:03/08/12` 的故障都带同一个签名：

```text
com.apple.coreaudio.avfaudio error 2003329396
failed call=PerformCommand(*ioNode, kAUStartIO, ...)
```

这一类故障发生在 `AVAudioEngine.start()` 之前或之时，和 `4/14-4/15` 那种 “engine 没报错但 2 秒内没首包” 不是同一类。

所以最近一周其实至少有两条根因链：

- 一条是启动级失败（`2003329396`）
- 一条是“没有首个有效音频”的 readiness/device-binding 问题

前面 5 个 commit 把它们混在一起修，才会出现“修掉一个表象，又冒出另一个”的感觉。

## 3. 证据链

### 3.1 当前系统状态和持久化配置不一致

证据：

- `defaults read com.speaklow.app`：
  - `asr_mode = streaming`
  - `selected_microphone_id = BuiltInMicrophoneDevice`
- CoreAudio 当前设备：
  - `default=true uid=AC-33-28-F0-AB-73:input name=HUAWEI FreeBuds 6i`
  - `default=false uid=BuiltInMicrophoneDevice name=MacBook Air麦克风`

推理：

- 用户配置意图是“内置麦克风”。
- 但系统默认输入是蓝牙耳机。
- 代码又不验证 `CurrentDevice` 设置是否真的生效，因此“期望值”和“实际录音值”可能长期漂移而不自知。

### 3.2 最新失败不是 bridge 没连上，而是“没有首个有效音频”

证据：

- `2026-04-15 00:25:17` `handleHotkeyDown()`
- `2026-04-15 00:25:18` `WS connected ... bridge connected`
- `2026-04-15 00:25:20` `Silence timeout — stopping recording and showing error`
- 期间没有 `Sound 'Tink' played`、没有 `Streaming partial`

推理：

- WS 正常。
- 失败发生在“音频 ready”之前。
- 这和 `4/10` 的 `2003329396` 完全不是一个阶段。

### 3.3 旧的次生症状都来自“过早进入 active state”

证据 1：`4/10 13:09:11`

- 录音启动已经报错 `2003329396`
- 但 `13:09:12` 仍然出现 `WS connected`

证据 2：`4/14 01:45:32`

- 先 silence timeout
- 到 `01:45:36` 热键抬起时，日志还是 `isRecording=false, isStreaming=true`

推理：

- WS/session 状态先行于 microphone ready。
- 这解释了为什么会出现 WebSocket 泄漏、stale callback、卡住感。

### 3.4 “0ms 丢弃” 不是用户真只说了 0ms，而是 `recordingStartTime` 根本没被设置

证据：

- `recordingStartTime` 在 `onRecordingReady` 中设置。[`speaklow-app/Sources/AppState.swift:845-850`]
- `stopStreamingRecording()` 用它来计算 elapsed；没 ready 就是 0。[`speaklow-app/Sources/AppState.swift:1051-1068`]
- 例如：
  - `2026-04-14 01:45:40` 开始
  - `2026-04-14 01:45:43` 抬键
  - `2026-04-14 01:45:44` 却记录成 `录音时长 0ms < 200ms，丢弃`

推理：

- 这不是“用户只按了 0ms”。
- 这是“这次录音从来没有进入 ready 状态”。

### 3.5 当前版本已经失去麦克风选择 UI

证据：

- 规格仍写着：
  - `docs/specs/prd.md:47` `麦克风选择：可切换输入设备`
  - `docs/specs/architecture.md:41` `SettingsView.swift | 设置面板（热键、麦克风、LLM 模式）`
- 但当前 `SettingsView` 的 `generalTab` 和 `recognitionTab` 里没有任何麦克风选择控件。[`speaklow-app/Sources/SettingsView.swift:127-308`]
- 初始版本确实有 `Section("Microphone") { Picker("Input Device", selection: $appState.selectedMicrophoneID) ... }`，后来在 `c6344f2` 的 settings 重构中被删掉了。

推理：

- 代码仍依赖 `selected_microphone_id`。
- 但用户已经无法在 UI 中查看/修正它。
- 这让“设备选择漂移”更难发现，也让错误提示“去设置里切换到内置麦克风”在当前版本事实上不可操作。

## 4. 为什么前面 5 个修复没根治

### `d04b92e`

它修了什么：

- 双实例竞争
- bridge restart circuit breaker

证据：

- `2026-04-10 13:09:10` 同一秒内重复 `startRecording()` / `AXIsProcessTrusted()`，明显有双实例或重复 hotkey 竞争。
- 同时有大量 `Bridge 崩溃（exit 1）...`。

为什么没根治：

- 它没有触碰 microphone readiness，也没有触碰设备绑定验证。
- 所以它只能消掉 `4/10` 那批“桥接/实例”噪音，根本碰不到 `4/14-4/15` 的 silence timeout。

### `2771717`

它修了什么：

- 识别 `2003329396`，把错误文案从“麦克风启动失败”改成“麦克风权限需要重新授权”。

为什么没根治：

- 它只改变错误分类和提示文案。[`speaklow-app/Sources/AppState.swift:459-477`]
- 对 “engine 启动成功但 2 秒内没有首个有效音频” 这条链完全无效。

### `114cdf3`

它修了什么：

- `invalidateEngine()` 后重试前加 `200ms` sleep。

为什么没根治：

- 它只影响 “启动报错后再试一次” 的 timing。
- 最新问题不是 retry timing，而是 **根本没有首个有效音频到达**。

### `6f93e6d`

它修了什么：

- mic failure 后清理 WebSocket
- 避免 stale callback
- 顺手修了 double refine / partial log flood

为什么没根治：

- 这批改动都是“失败后的次生清理”。
- 它确实减少了泄漏/卡住感，但没有解释也没有修正 “为什么没有首个有效音频”。

### `8f8b518`

它修了什么：

- silence timeout 后补做 WS cleanup
- 蓝牙提示
- `make install` 变安全

为什么没根治：

- 这仍然是 **失败之后** 的清理和提示，不是失败之前的验证。
- 它把 “清理没做” 修掉了，但没把 “为什么没 ready” 修掉。
- 日志已经证明：commit 后 5 小时内又连续出现 5 次 silence timeout。

## 5. 修复建议（按优先级）

### P0. 把“实际录音设备”和“录音是否 ready”做成一等状态

文件：

- `speaklow-app/Sources/AudioRecorder.swift`
- `speaklow-app/Sources/AppState.swift`

改动点：

1. `AudioUnitSetProperty(CurrentDevice)` 必须检查返回值。
2. 设置后立刻 read-back 当前 `CurrentDevice`，写入文件日志。
3. 如果选中设备不存在、设置失败、read-back 不一致，不要静默继续；要么显式回退，要么明确报错。
4. 把 session 状态拆成至少三段：
   - `pressed`
   - `capturingReady`
   - `streamingConnected`
5. `isRecording=true` 不要在热键按下就设置；至少要等 engine start 成功，最好等首个有效 buffer。

### P0. 把关键音频诊断从 `os_log` 提升到文件日志

文件：

- `speaklow-app/Sources/AudioRecorder.swift`
- `speaklow-app/Sources/AppState.swift`

原因：

- 当前快照几乎没有 `AudioRecorder` 的设备/format/buffer 日志，因为这些写到了 `os_log`，不在文件日志里。
- 这直接导致这次调查无法证明 `4/14-4/15` 时 engine 实际绑到了哪只设备。

至少要记录：

- selected UID
- default UID
- actual bound UID（read-back）
- `AudioUnitSetProperty` 的 `OSStatus`
- input format（sample rate/channel）
- first buffer 到达时间
- first non-silent buffer 到达时间
- silence timeout 时最近 10 个 buffer 的 RMS

### P1. 恢复麦克风选择 UI，并在启动时校验持久化值

文件：

- `speaklow-app/Sources/SettingsView.swift`
- `speaklow-app/Sources/AppState.swift`

改动点：

1. 恢复 microphone picker；当前版本用户无法修正 `selected_microphone_id`。
2. 启动时验证 `selected_microphone_id` 是否仍在 `availableMicrophones` 中。
3. 如果无效，显式改回 `default` 或 `built-in`，并记录日志。

### P1. 不要在 silence timeout 里拿“默认设备”冒充“实际录音设备”

文件：

- `speaklow-app/Sources/AppState.swift`

改动点：

- `silence timeout` 的提示逻辑应基于 `actual bound device`，不是 `AudioDevice.defaultInputDeviceUID()`。
- 否则会把调查方向带偏。

### P2. 区分“用户沉默”和“设备没音频”

文件：

- `speaklow-app/Sources/AudioRecorder.swift`
- `speaklow-app/Sources/AppState.swift`

改动点：

1. 不要把 “2 秒没非静音” 直接等同于“麦克风坏了”。
2. 至少区分：
   - 完全没有 buffer
   - 有 buffer 但 RMS 恒为 0
   - 有低电平 buffer
   - 用户松手前一直没说话
3. UI 文案也要分开，否则继续误导用户和开发者。

### P2. bridge 崩溃原因要写进文件日志

文件：

- `speaklow-app/Sources/ASRBridgeManager.swift`

改动点：

- 当前日志只有 `Bridge 崩溃（exit 1）`，没有 crash reason。
- 应把 bridge stdout/stderr 关键行同步进 `viLog`，否则永远只能看见“崩了”，看不见“为什么崩”。

## 6. 未解之谜

### 6.1 `4/14-4/15` 的“无首个有效音频”到底是哪个物理触发？

当前只能确认：

- 2 秒内没有首个有效音频；
- 当前默认输入是蓝牙；
- 代码没有验证实际绑定设备。

但无法用当前材料证明到底是哪一个：

- 用户前 2 秒没说话
- 蓝牙麦克风静默
- 设备绑定悄悄回退到默认蓝牙
- 目标设备绑定失败

要确认这个问题，需要补充：

- `AudioRecorder` 的实际绑定设备 read-back 日志
- buffer 级 RMS/format 文件日志

### 6.2 `4/10` 的 bridge `exit 1` 精确原因是什么？

当前日志只有 crash loop，没有 bridge stderr。

要确认，需要补充：

- bridge stdout/stderr 落盘
- 或当时的 macOS unified log / crash report

### 6.3 “麦克风权限被系统反复要求”是否真的发生过多次？

用户口述提到了这一点，但当前文件日志没有这类系统弹窗证据。

要确认，需要补充：

- 系统 TCC 日志
- 或带时间戳的屏幕录屏 / unified log

## 最终判断

如果只问一句“为什么前面 5 次都是修一个症状、又冒出另一个”，答案是：

> 因为 SpeakLow 一直没有一个可信的“麦克风已经真正绑定并开始产出可用音频”的判断点。  
> 代码只记录想录哪只麦克风，不验证实际录到哪只；又在拿到首个有效音频之前就把 session 视为开始。  
> 所以前面的 commit 大多都在清理二次症状，而不是修这个判断模型本身。

而如果只问“最新重启后仍然出现的 silence timeout 是不是已经查到唯一物理根因”，诚实答案是：

> 还没有。  
> 目前能确定的是：这不是 `2003329396` 那条旧问题；它属于“前 2 秒没有首个有效音频”的新问题族。  
> 但因为当前日志缺少实际设备绑定和 buffer 级证据，无法在现有材料里把它唯一锁死到“蓝牙静默”或“设备选择失败”之一。
