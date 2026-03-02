package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"
)

const (
	qwenChatURL   = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
	refineModel   = "qwen-turbo-latest"
	refineTimeout = 10 * time.Second
)

const refineEnglishRule = `
【最重要的规则】所有英文必须原样保留，严禁翻译成中文！用户是程序员，中英混说是刻意的。
正确示例：
输入：嗯那个这个API的response time太长了需要优化一下performance
输出：这个API的response time太长了，需要优化一下performance。
错误示例（绝对不要这样做）：
输出：这个API的响应时间太长了，需要优化一下性能。`

var refinePrompts = map[string]string{
	"correct": "你是语音转文字纠错助手。直接输出修正后的文本，不加任何解释。\n规则：修正同音字错误、补充标点符号、保留原意不改写。" + refineEnglishRule,
	"polish":  "你是语音转文字润色助手。直接输出优化后的文本，不加任何解释。\n规则：优化语句通顺度、去除口语化表达、使文字更书面化，保留原意。" + refineEnglishRule,
	"both":    "你是语音转文字优化助手。直接输出优化后的文本，不加任何解释。\n规则：修正同音字错误、补充标点符号、优化语句通顺度、去除口语化冗余词（嗯、啊、那个），保留原意。" + refineEnglishRule,
}

type refineRequest struct {
	Text string `json:"text"`
	Mode string `json:"mode"` // "correct", "polish", "both"
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

		// Default mode
		if req.Mode == "" {
			req.Mode = "both"
		}
		systemPrompt, ok := refinePrompts[req.Mode]
		if !ok {
			writeError(w, http.StatusBadRequest, fmt.Sprintf("invalid mode: %s", req.Mode))
			return
		}

		start := time.Now()
		refined, err := callQwenRefine(apiKey, systemPrompt, req.Text)
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
	body := map[string]any{
		"model": refineModel,
		"messages": []map[string]string{
			{"role": "system", "content": systemPrompt},
			{"role": "user", "content": text},
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

	return result.Choices[0].Message.Content, nil
}
