package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	qwenChatURL   = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
	refineModel   = "qwen-flash"
	refineTimeout = 10 * time.Second
)

// refinePreamble is loaded from refine_preamble.txt at startup.
// It defines the data boundary (transcription != instruction) to prevent prompt injection.
// Separated from refinePrompt so users can customize rules without breaking safety.
var refinePreamble string

// refinePrompt is the user-configurable rules prompt. Empty = use preamble only.
var refinePrompt string

// styleRules maps style name → extra instruction appended to base prompt.
var styleRules map[string]string

// configPaths caches the resolved lookup paths (computed once at startup).
var preamblePaths []string
var promptPaths []string
var styleDirs []string

// lastConfigMtime tracks the newest mtime across all config files.
// Only reload when any file has been modified.
var lastConfigMtime time.Time

func initConfigPaths() {
	exe, _ := os.Executable()
	exeDir := filepath.Dir(exe)

	// preamble 不走用户配置目录，只从 bundle Resources 加载
	preamblePaths = []string{
		filepath.Join(exeDir, "..", "Resources", "refine_preamble.txt"),
		filepath.Join(exeDir, "..", "speaklow-app", "Resources", "refine_preamble.txt"),
	}
	promptPaths = []string{
		expandHome("~/.config/speaklow/refine_prompt.txt"),
		filepath.Join(exeDir, "..", "Resources", "refine_prompt.txt"),
		filepath.Join(exeDir, "..", "speaklow-app", "Resources", "refine_prompt.txt"),
	}
	styleDirs = []string{
		filepath.Join(exeDir, "..", "Resources", "refine_styles"),
		filepath.Join(exeDir, "..", "speaklow-app", "Resources", "refine_styles"),
		expandHome("~/.config/speaklow/refine_styles"),
	}
}

// configChanged checks if any config file has been modified since last load.
func configChanged() bool {
	var newest time.Time
	// 检查 preamble 文件
	for _, path := range preamblePaths {
		if path == "" {
			continue
		}
		if info, err := os.Stat(path); err == nil {
			if info.ModTime().After(newest) {
				newest = info.ModTime()
			}
		}
	}
	// 检查基础 prompt 文件
	for _, path := range promptPaths {
		if path == "" {
			continue
		}
		if info, err := os.Stat(path); err == nil {
			if info.ModTime().After(newest) {
				newest = info.ModTime()
			}
		}
	}
	// 检查风格目录
	for _, dir := range styleDirs {
		if dir == "" {
			continue
		}
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, entry := range entries {
			if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".txt") {
				continue
			}
			if info, err := entry.Info(); err == nil {
				if info.ModTime().After(newest) {
					newest = info.ModTime()
				}
			}
		}
	}
	return newest.After(lastConfigMtime)
}

// loadRefinePrompt loads base prompt and style rules from config files.
// No hardcoded prompts — all content comes from files.
func loadRefinePrompt() {
	refinePreamble = ""
	refinePrompt = ""
	styleRules = map[string]string{"default": ""}

	// 加载 preamble（数据边界声明，防止指令注入）
	for _, path := range preamblePaths {
		if path == "" {
			continue
		}
		if data, err := os.ReadFile(path); err == nil {
			if content := strings.TrimSpace(string(data)); content != "" {
				refinePreamble = content
				log.Printf("loaded refine preamble from %s", path)
				break
			}
		}
	}
	if refinePreamble == "" {
		log.Println("WARNING: no refine_preamble.txt found, transcription data boundary not set")
	}

	// 加载用户自定义修正规则
	for _, path := range promptPaths {
		if path == "" {
			continue
		}
		if data, err := os.ReadFile(path); err == nil {
			if content := strings.TrimSpace(string(data)); content != "" {
				refinePrompt = content
				log.Printf("loaded refine prompt from %s", path)
				break
			}
		}
	}
	if refinePrompt == "" {
		log.Println("WARNING: no refine_prompt.txt found, LLM refinement will be skipped")
	}

	for _, dir := range styleDirs {
		if dir == "" {
			continue
		}
		loadStylesFromDir(dir)
	}

	lastConfigMtime = time.Now()

	names := make([]string, 0, len(styleRules))
	for k := range styleRules {
		names = append(names, k)
	}
	log.Printf("refine styles available: %v", names)
}

// reloadIfChanged checks file mtimes and reloads config only when files have changed.
func reloadIfChanged() {
	if configChanged() {
		log.Println("refine config files changed, reloading...")
		loadRefinePrompt()
	}
}

func loadStylesFromDir(dir string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".txt") {
			continue
		}
		name := strings.TrimSuffix(entry.Name(), ".txt")
		data, err := os.ReadFile(filepath.Join(dir, entry.Name()))
		if err != nil {
			continue
		}
		if content := strings.TrimSpace(string(data)); content != "" {
			styleRules[name] = "\n" + content
		}
	}
}

// buildPrompt combines preamble, user-configurable base prompt, and style rule.
func buildPrompt(style string) string {
	parts := refinePreamble
	if refinePrompt != "" {
		if parts != "" {
			parts += "\n"
		}
		parts += refinePrompt
	}
	if rule, ok := styleRules[style]; ok && rule != "" {
		parts += rule
	}
	return parts
}

type refineRequest struct {
	Text  string `json:"text"`
	Style string `json:"style"` // "default", "business", "chat", or custom
}

func refineHandler(apiKey string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}

		var req refineRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, fmt.Sprintf("decode: %v", err))
			return
		}
		if req.Text == "" {
			writeError(w, http.StatusBadRequest, "text is empty")
			return
		}
		if req.Style == "" {
			req.Style = "default"
		}

		// mtime 检查，文件变了才重新加载
		reloadIfChanged()

		// preamble 和 prompt 都为空时跳过 LLM，直接返回原文
		if refinePreamble == "" && refinePrompt == "" {
			writeJSON(w, http.StatusOK, map[string]any{
				"refined_text": req.Text,
				"duration_ms":  0,
				"fallback":     true,
				"error":        "no refine prompt configured",
			})
			return
		}

		prompt := buildPrompt(req.Style)
		start := time.Now()
		refined, err := callQwenRefine(apiKey, prompt, req.Text)
		durationMs := time.Since(start).Milliseconds()

		if err != nil {
			log.Printf("refine error (%.0fms): %v, returning original text", float64(durationMs), err)
			// Graceful degradation: return original text
			writeJSON(w, http.StatusOK, map[string]any{
				"refined_text": req.Text,
				"duration_ms":  durationMs,
				"fallback":     true,
				"error":        err.Error(),
			})
			return
		}

		log.Printf("refine ok (%.0fms): %d→%d chars", float64(durationMs), len(req.Text), len(refined))
		writeJSON(w, http.StatusOK, map[string]any{
			"refined_text": refined,
			"duration_ms":  durationMs,
		})
	}
}

func callQwenRefine(apiKey, systemPrompt, text string) (string, error) {
	// 用 delimiter 包裹转写文本，从结构上隔离"指令"和"数据"
	userContent := "<transcription>\n" + text + "\n</transcription>"

	body := map[string]any{
		"model": refineModel,
		"messages": []map[string]string{
			{"role": "system", "content": systemPrompt},
			{"role": "user", "content": userContent},
		},
		"temperature": 0.2,
		"max_tokens":  500,
	}
	bodyBytes, err := json.Marshal(body)
	if err != nil {
		return "", fmt.Errorf("marshal: %w", err)
	}

	client := &http.Client{Timeout: refineTimeout}
	req, err := http.NewRequest(http.MethodPost, qwenChatURL, bytes.NewReader(bodyBytes))
	if err != nil {
		return "", fmt.Errorf("new request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("http: %w", err)
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("read body: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("status %d: %s", resp.StatusCode, string(raw))
	}

	var result struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		return "", fmt.Errorf("unmarshal: %w", err)
	}
	if len(result.Choices) == 0 || result.Choices[0].Message.Content == "" {
		return "", fmt.Errorf("empty response from model")
	}

	refined := result.Choices[0].Message.Content

	// 长度兜底：如果输出远超输入，说明模型在"发挥"而非修正，回退原文
	inputRunes := []rune(text)
	outputRunes := []rune(refined)
	if len(inputRunes) > 0 && len(outputRunes) > len(inputRunes)*3 {
		log.Printf("refine length guard: output %d chars vs input %d chars (%.1fx), returning original",
			len(outputRunes), len(inputRunes), float64(len(outputRunes))/float64(len(inputRunes)))
		return text, nil
	}

	return refined, nil
}
