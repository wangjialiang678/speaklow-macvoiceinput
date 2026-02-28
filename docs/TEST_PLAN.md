# VoiceInput 测试方案

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

## 2. Voice Input App 测试

### 2.1 编译测试

```bash
cd voice-input-app
make all  # 必须编译通过
```

### 2.2 功能测试（手动）

| 测试项 | 步骤 | 预期 |
|--------|------|------|
| 启动 | 双击 VoiceInput.app | 菜单栏出现图标，ASR Bridge 自动启动 |
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
| 无网络 | 显示连接错误提示 |
| API Key 缺失 | 显示配置提示 |
| 极短录音（<0.5s）| 提示无内容可转写 |
| 长录音（>30s）| 正常识别返回 |
| ASR Bridge 崩溃 | App 自动重启 Bridge |

## 3. 端到端测试流程

1. 构建 asr-bridge 二进制 → 验证 health 端点
2. 用 curl 上传测试音频 → 验证转写结果
3. 构建 VoiceInput.app → 验证内含 asr-bridge
4. 启动 App → 验证 Bridge 自动启动
5. 录音测试 → 验证完整流程
