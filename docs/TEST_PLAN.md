# SpeakLow 测试方案

## 1. ASR Bridge 测试

### 1.1 单元测试

| 测试项 | 说明 |
|--------|------|
| TestLoadEnv | .env 文件加载，优先级正确 |
| TestHealthEndpoint | GET /health 返回 200 |
| TestTranscribeNoFile | 缺少文件时返回 400 |
| TestTranscribeEmptyFile | 空文件返回错误 |

### 1.2 集成测试（需要 API Key）

| 测试项 | 说明 |
|--------|------|
| TestTranscribeWAV | 上传 WAV 文件，验证返回文本非空 |
| TestTranscribeTimeout | 大文件超时处理 |

### 1.3 手动测试

```bash
# 启动服务
DASHSCOPE_API_KEY=xxx ./asr-bridge

# 测试健康检查
curl http://localhost:18089/health

# 测试转写
curl -X POST http://localhost:18089/v1/transcribe \
  -F "file=@test.wav" \
  -F "format=wav"
```

## 2. SpeakLow App 测试

### 2.1 编译测试

```bash
cd speaklow-app
make all  # 必须编译通过
```

### 2.2 功能测试（手动）

| 测试项 | 步骤 | 预期 |
|--------|------|------|
| 启动 | 双击 SpeakLow.app | 菜单栏出现图标，ASR Bridge 自动启动 |
| 权限引导 | 首次启动 | 弹出权限引导窗口 |
| 录音 | 按住 Fn 键 | 屏幕顶部出现录音波形 |
| 停止并转写 | 松开 Fn 键 | 波形消失，显示转写中指示器 |
| 文字插入 | 在文本编辑器中录音 | 识别文字自动插入光标位置 |
| 插入失败回退 | 在无文本框的应用中 | 提示用户文字已复制到剪贴板 |
| 切换快捷键 | 设置中切换到 F5 | F5 键触发录音 |
| 退出 | 点击菜单栏 Quit | App 退出，ASR Bridge 进程也结束 |

### 2.3 边界条件

| 测试项 | 预期 |
|--------|------|
| 无网络 | 显示"网络连接超时 / 请检查网络连接" |
| API Key 缺失 | 显示配置提示 |
| 极短录音（<0.5s）| 显示"未检测到语音 / 请靠近麦克风说话" |
| 长录音（>30s）| 正常识别返回 |
| ASR Bridge 崩溃 | 自动重启 Bridge，显示初始化动画 |

### 2.4 自检与自愈测试

| 测试项 | 步骤 | 预期 |
|--------|------|------|
| Bridge 自动重启 | `pkill -f asr-bridge` → 按快捷键录音 | 显示初始化动画 → 自动重启 bridge → 继续录音 |
| Bridge 重启失败 | 删除 asr-bridge 二进制 → 按快捷键 | 显示"语音服务未启动 / 请重启 SpeakLow" |
| 静音超时检测 | 选择虚拟音频设备 → 按快捷键 | 2 秒后显示"麦克风无响应 / 请检查麦克风或重启应用" |
| 静音后恢复 | 静音超时后 → 切回正常麦克风 → 再次按快捷键 | 引擎自动重建，正常录音 |
| 波形动画流畅性 | 正常录音，观察波形 | 波形流畅跟随语音，无明显卡顿 |
| 转录失败自愈 | 录音过程中 `pkill -f asr-bridge` → 松开快捷键 | 显示错误提示，后台自动重启 bridge |
| 重启反馈 | Bridge 不健康时按快捷键 | 显示初始化动画（三个跳动的点）+ 状态"正在恢复服务..." |

### 2.5 手动自愈测试流程

```bash
# 1. 正常启动 app
open speaklow-app/build/SpeakLow.app

# 2. 等待启动完成，验证 bridge 健康
sleep 5 && curl -s http://localhost:18089/health
# 预期输出: {"status":"ok"}

# 3. 手动杀掉 bridge
pkill -f asr-bridge

# 4. 验证 bridge 已停止
curl -s http://localhost:18089/health || echo "Bridge is DOWN"

# 5. 按快捷键录音 → 观察 overlay 显示初始化动画
# 6. 等待几秒后，bridge 应自动恢复
curl -s http://localhost:18089/health
# 预期输出: {"status":"ok"}

# 7. 检查日志确认自动重启
tail -20 ~/Library/Logs/SpeakLow.log | grep -i "restart\|auto\|ensureRunning"
```

## 3. 端到端测试流程

1. 构建 asr-bridge 二进制 → 验证 health 端点
2. 用 curl 上传测试音频 → 验证转写结果
3. 构建 SpeakLow.app → 验证内含 asr-bridge
4. 启动 App → 验证 Bridge 自动启动
5. 录音测试 → 验证完整流程
6. 杀掉 bridge → 录音 → 验证自动重启
7. 检查所有 UI 文本显示为 "SpeakLow"（非 "VoiceInput"）
