package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

const qwen3ASREndpoint = "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"

func transcribeSyncHandler(apiKey string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}

		if err := r.ParseMultipartForm(maxUploadSize); err != nil {
			writeError(w, http.StatusBadRequest, fmt.Sprintf("parse form: %v", err))
			return
		}

		file, _, err := r.FormFile("file")
		if err != nil {
			writeError(w, http.StatusBadRequest, fmt.Sprintf("get file: %v", err))
			return
		}
		defer file.Close()

		audioData, err := io.ReadAll(file)
		if err != nil {
			writeError(w, http.StatusInternalServerError, fmt.Sprintf("read file: %v", err))
			return
		}

		start := time.Now()
		text, err := transcribeWithQwen3(apiKey, audioData)
		if err != nil {
			writeError(w, http.StatusInternalServerError, fmt.Sprintf("transcribe: %v", err))
			return
		}
		durationMs := time.Since(start).Milliseconds()

		writeJSON(w, http.StatusOK, map[string]any{
			"text":        text,
			"duration_ms": durationMs,
		})
	}
}

func transcribeWithQwen3(apiKey string, audioData []byte) (string, error) {
	b64 := base64.StdEncoding.EncodeToString(audioData)
	audioURI := "data:audio/wav;base64," + b64

	systemText := qwen3Hotwords

	type contentItem map[string]string
	type message struct {
		Role    string        `json:"role"`
		Content []contentItem `json:"content"`
	}
	type requestBody struct {
		Model string `json:"model"`
		Input struct {
			Messages []message `json:"messages"`
		} `json:"input"`
		Parameters struct {
			ASROptions struct {
				LanguageHints []string `json:"language_hints"`
			} `json:"asr_options"`
		} `json:"parameters"`
	}

	var req requestBody
	model := os.Getenv("ASR_SYNC_MODEL")
	if model == "" {
		model = "qwen3-asr-flash"
	}
	req.Model = model

	var msgs []message
	if systemText != "" {
		msgs = append(msgs, message{
			Role:    "system",
			Content: []contentItem{{"text": systemText}},
		})
	}
	msgs = append(msgs, message{
		Role:    "user",
		Content: []contentItem{{"audio": audioURI}},
	})
	req.Input.Messages = msgs
	req.Parameters.ASROptions.LanguageHints = []string{"zh", "en"}

	body, err := json.Marshal(req)
	if err != nil {
		return "", fmt.Errorf("marshal request: %w", err)
	}

	httpReq, err := http.NewRequest(http.MethodPost, qwen3ASREndpoint, bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("create request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Authorization", "Bearer "+apiKey)

	client := &http.Client{Timeout: 60 * time.Second}
	resp, err := client.Do(httpReq)
	if err != nil {
		return "", fmt.Errorf("http request: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("read response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("api error %d: %s", resp.StatusCode, string(respBody))
	}

	var result struct {
		Output struct {
			Choices []struct {
				Message struct {
					Content []struct {
						Text string `json:"text"`
					} `json:"content"`
				} `json:"message"`
			} `json:"choices"`
		} `json:"output"`
	}
	if err := json.Unmarshal(respBody, &result); err != nil {
		return "", fmt.Errorf("parse response: %w", err)
	}
	if len(result.Output.Choices) == 0 || len(result.Output.Choices[0].Message.Content) == 0 {
		return "", fmt.Errorf("empty response")
	}

	return result.Output.Choices[0].Message.Content[0].Text, nil
}
