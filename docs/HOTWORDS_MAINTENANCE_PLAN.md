# 热词表维护方案设计

> **版本**: v1.0 (2026-03-02)
> **关联**: [AI 开发者热词表](./HOTWORDS_AI_DEV.md)

## 1. 问题定义

AI 领域工具和术语更新极快（月级别出现新工具），语音输入场景下：
- ASR 对英文专有名词识别率低（如 "shadcn" → "沙德CN"、"Supabase" → "素泊贝斯"）
- 新工具名出现后如不及时加入热词表，用户需要反复手动纠正
- 静态热词表会在 3-6 个月内严重过时

**目标**: 建立一套低维护成本、高时效性的热词表更新机制。

---

## 2. 热词表数据格式

### 2.1 存储格式

热词表用 JSON 格式存储（方便程序读取 + 人工编辑），配合 Markdown 文档做可读版本。

```
speaklow-app/resources/
├── hotwords.json          # 机器可读格式（程序加载用）
├── hotwords-custom.json   # 用户自定义热词（优先级最高，不会被更新覆盖）
```

```json
// hotwords.json 示例
{
  "version": "1.0.0",
  "updated_at": "2026-03-02",
  "categories": {
    "ai_coding_assistants": {
      "label": "AI 编码助手",
      "words": [
        {
          "word": "Claude Code",
          "aliases": ["克劳德 Code", "克劳德code"],
          "priority": "P0",
          "added": "2026-03-02"
        },
        {
          "word": "Cursor",
          "aliases": ["克瑟"],
          "priority": "P0",
          "added": "2026-03-02"
        }
      ]
    }
  }
}
```

### 2.2 用户自定义热词

```json
// hotwords-custom.json 示例 — 用户自行维护，永不被覆盖
{
  "words": [
    {
      "word": "SpeakLow",
      "aliases": ["斯匹克楼"],
      "priority": "P0"
    },
    {
      "word": "DashScope",
      "aliases": ["百炼", "达什斯科普"],
      "priority": "P0"
    }
  ]
}
```

---

## 3. 更新策略（三层架构）

```
┌──────────────────────────────────────┐
│  Layer 3: 用户自定义 (最高优先级)      │  hotwords-custom.json
│  用户手动添加的个人/项目专属词汇         │  永不被覆盖
├──────────────────────────────────────┤
│  Layer 2: 社区/AI 自动更新             │  hotwords.json
│  定期从 AI 或社区数据源自动补充新词      │  可自动更新
├──────────────────────────────────────┤
│  Layer 1: 基础词表 (内置)              │  编译进 app
│  Git/GitHub/React 等永远不会过时的基础词 │  随版本发布
└──────────────────────────────────────┘
```

**合并优先级**: Layer 3 > Layer 2 > Layer 1（同名词条以高层为准）

---

## 4. 四种更新方式

### 4.1 手动维护（当前）

**适合**: 初期（v1.0），热词量少（<300 词）

- 编辑 `docs/HOTWORDS_AI_DEV.md`（人读）
- 用脚本同步到 `hotwords.json`（机读）
- 每月人工 review 一次

**工具**: 写一个 `scripts/hotwords_md_to_json.py` 做 Markdown → JSON 转换

### 4.2 LLM 辅助更新（推荐，短期方案）

**适合**: v1.1+，利用 Claude / GPT 自动补充新词

**流程**:
```
每月触发 → LLM 联网搜索近期 AI 开发领域新词
         → 与现有热词表对比（去重）
         → 生成 diff（新增/删除/降级）
         → 人工 review & approve
         → 合并到 hotwords.json
```

**实现方式**:
- 写一个 Claude Code Skill 或脚本，prompt 如下：
  > "搜索过去 30 天 AI 开发领域的新工具、新框架、新模型名称。
  > 与以下现有热词表对比，输出：新增词条、应删除的过时词条、应降级的词条。
  > 输出 JSON 格式。"
- 每月 1 号自动触发（GitHub Actions cron 或本地 cron）
- 输出 PR 或 diff 文件，人工确认

**优点**: 低成本、覆盖面广、可追溯
**缺点**: 需要人工最终确认

### 4.3 社区众包（中期方案）

**适合**: 如果 SpeakLow 开源且有用户

- 在 GitHub 开一个 `hotwords/` 目录接受 PR
- 提供贡献模板（词条格式、分类、优先级）
- 通过 CI 自动校验格式

### 4.4 使用数据驱动（长期方案）

**适合**: 用户量大之后

**原理**: 通过分析用户的纠正行为自动发现需要加入热词的新词

```
用户说 "用 Cursor 写代码"
→ ASR 识别为 "用克涩写代码"
→ 用户手动改为 "用 Cursor 写代码"
→ 记录纠正对: ("克涩" → "Cursor")
→ 某个纠正对出现 N 次后 → 自动建议加入热词表
```

**实现要点**:
- 在 TextInserter 层记录"用户修改前 vs 修改后"的 diff
- 本地存储纠正日志（隐私友好，不上传）
- 定期分析高频纠正对，生成建议热词
- 用户确认后加入 `hotwords-custom.json`

---

## 5. DashScope 热词接入方案

### 5.1 DashScope API 支持

DashScope Paraformer 支持两种热词方式：

1. **`vocabulary_id`** — 预先在控制台/API 创建词表，传 ID 引用
2. **`hotwords`** — 请求级内联热词（适合动态词表）

推荐使用方式 2（内联），更灵活：

```go
// asr-bridge/transcribe.go 中添加
Parameters: map[string]any{
    "format":                       format,
    "sample_rate":                  sampleRate,
    "semantic_punctuation_enabled": true,
    "language_hints":               []string{"zh", "en"},
    "hotwords": buildHotwordString(), // 新增
}
```

### 5.2 热词格式

DashScope 内联热词格式: `{"热词1": 权重, "热词2": 权重}`
- 权重范围: 1-5（越高越优先识别）
- P0 词 → 权重 5
- P1 词 → 权重 3
- P2 词 → 权重 1

```go
func buildHotwordString() string {
    // 从 hotwords.json + hotwords-custom.json 加载
    // 按优先级映射权重
    // 输出: {"Claude Code": 5, "Cursor": 5, "Windsurf": 3, ...}
}
```

### 5.3 热词数量限制

DashScope 单次请求热词上限约 **200 个**（需确认最新文档）。

**策略**: 只加载 P0 + P1 词条（约 215 个），或按用户最近使用频率动态选取 Top 200。

---

## 6. 维护节奏建议

| 频率 | 动作 | 负责方 |
|------|------|--------|
| 每月 | LLM 自动扫描新词 + 人工 review | 自动 + 人工 |
| 每季度 | 全面 review，清理过时词条 | 人工 |
| 每个大版本 | 基础词表随版本发布更新 | 开发者 |
| 实时 | 用户自定义热词 | 用户 |

---

## 7. 实施路线图

### Phase 1: 基础版（本周可完成）
- [x] 整理热词表 Markdown 文档
- [ ] 编写 `hotwords_md_to_json.py` 转换脚本
- [ ] 在 asr-bridge 中添加 `hotwords` 参数传递
- [ ] 加载 `hotwords.json` 并传入 DashScope API

### Phase 2: 用户自定义（1-2 周）
- [ ] 支持 `hotwords-custom.json`
- [ ] 在 Settings UI 添加"自定义热词"入口
- [ ] 合并逻辑（custom > default）

### Phase 3: LLM 自动更新（1 个月内）
- [ ] 编写 LLM 更新脚本/Skill
- [ ] 设置月度 cron 触发
- [ ] 输出 diff 供 review

### Phase 4: 使用数据驱动（长期）
- [ ] 记录用户纠正行为
- [ ] 分析高频纠正对
- [ ] 自动建议新热词

---

## 8. 补充思考

### 8.1 多词表支持

未来可以按场景提供多份词表：
- `hotwords-ai-dev.json` — AI 开发（当前）
- `hotwords-medical.json` — 医疗领域
- `hotwords-legal.json` — 法律领域
- `hotwords-finance.json` — 金融领域

用户在 Settings 中选择启用哪些词表。

### 8.2 中英文混合优化

AI 开发者的典型语音输入：
> "用 **Cursor** 打开项目，然后用 **Claude Code** 写一个 **FastAPI** 的 **endpoint**"

这种中英文混合场景，热词表需要同时包含：
- 英文原词: `Cursor`, `Claude Code`, `FastAPI`
- 中文读音: `克瑟`, `克劳德`, `法斯特 API`（帮助 ASR 在纯中文语境中识别）

### 8.3 与 LLM 文本优化联动

当前 SpeakLow 已有 LLM refine 功能。热词表可以与之联动：
- ASR 层：热词提升识别率（输入端）
- LLM 层：在 refine prompt 中添加"将技术术语规范化"规则（输出端）
- 双重保障：即使 ASR 漏识别，LLM 也能纠正
