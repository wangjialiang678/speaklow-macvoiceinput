package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/gorilla/websocket"
)

const (
	dashscopeWSURL = "wss://dashscope.aliyuncs.com/api-ws/v1/inference"
	chunkSize      = 3200
	dialTimeout    = 8 * time.Second
	totalTimeout   = 30 * time.Second
)

type runTaskMsg struct {
	Header  runTaskHeader  `json:"header"`
	Payload runTaskPayload `json:"payload"`
}

type runTaskHeader struct {
	Action    string `json:"action"`
	TaskID    string `json:"task_id"`
	Streaming string `json:"streaming"`
}

type runTaskPayload struct {
	TaskGroup  string            `json:"task_group"`
	Task       string            `json:"task"`
	Function   string            `json:"function"`
	Model      string            `json:"model"`
	Parameters map[string]any    `json:"parameters"`
	Input      map[string]any    `json:"input"`
}

type finishTaskMsg struct {
	Header  finishTaskHeader  `json:"header"`
	Payload finishTaskPayload `json:"payload"`
}

type finishTaskHeader struct {
	Action    string `json:"action"`
	TaskID    string `json:"task_id"`
	Streaming string `json:"streaming"`
}

type finishTaskPayload struct {
	Input map[string]any `json:"input"`
}

type serverEvent struct {
	Header  serverEventHeader `json:"header"`
	Payload serverEventPayload `json:"payload"`
}

type serverEventHeader struct {
	Event      string `json:"event"`
	TaskID     string `json:"task_id"`
	ErrorCode  string `json:"error_code,omitempty"`
	ErrorMessage string `json:"error_message,omitempty"`
}

type serverEventPayload struct {
	Output serverEventOutput `json:"output"`
}

type serverEventOutput struct {
	Sentence *sentence `json:"sentence,omitempty"`
}

type sentence struct {
	Text        string `json:"text"`
	BeginTime   int    `json:"begin_time"`
	EndTime     int    `json:"end_time"`
	SentenceEnd bool   `json:"sentence_end"`
}

func randomTaskID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// transcribe sends audio data to DashScope FunASR and returns the recognized text.
func transcribe(apiKey string, audioData []byte, model string, sampleRate int, format string) (string, error) {
	taskID, err := randomTaskID()
	if err != nil {
		return "", fmt.Errorf("generate task id: %w", err)
	}

	dialer := websocket.Dialer{
		HandshakeTimeout: dialTimeout,
	}

	headers := http.Header{
		"Authorization":            []string{"bearer " + apiKey},
		"X-DashScope-DataInspection": []string{"enable"},
	}

	conn, _, err := dialer.Dial(dashscopeWSURL, headers)
	if err != nil {
		return "", fmt.Errorf("websocket dial: %w", err)
	}
	defer conn.Close()

	deadline := time.Now().Add(totalTimeout)
	if err := conn.SetReadDeadline(deadline); err != nil {
		return "", fmt.Errorf("set read deadline: %w", err)
	}
	if err := conn.SetWriteDeadline(deadline); err != nil {
		return "", fmt.Errorf("set write deadline: %w", err)
	}

	// Send run-task
	runTask := runTaskMsg{
		Header: runTaskHeader{
			Action:    "run-task",
			TaskID:    taskID,
			Streaming: "duplex",
		},
		Payload: runTaskPayload{
			TaskGroup: "audio",
			Task:      "asr",
			Function:  "recognition",
			Model:     model,
			Parameters: map[string]any{
				"format":                       format,
				"sample_rate":                  sampleRate,
				"semantic_punctuation_enabled": true,
			},
			Input: map[string]any{},
		},
	}

	if err := conn.WriteJSON(runTask); err != nil {
		return "", fmt.Errorf("send run-task: %w", err)
	}

	// Wait for task-started
	if err := waitForEvent(conn, "task-started"); err != nil {
		return "", fmt.Errorf("wait task-started: %w", err)
	}

	// Send audio in chunks
	for offset := 0; offset < len(audioData); offset += chunkSize {
		end := offset + chunkSize
		if end > len(audioData) {
			end = len(audioData)
		}
		if err := conn.WriteMessage(websocket.BinaryMessage, audioData[offset:end]); err != nil {
			return "", fmt.Errorf("send audio chunk at offset %d: %w", offset, err)
		}
	}

	// Send finish-task
	finishTask := finishTaskMsg{
		Header: finishTaskHeader{
			Action:    "finish-task",
			TaskID:    taskID,
			Streaming: "duplex",
		},
		Payload: finishTaskPayload{
			Input: map[string]any{},
		},
	}

	if err := conn.WriteJSON(finishTask); err != nil {
		return "", fmt.Errorf("send finish-task: %w", err)
	}

	// Collect results until task-finished
	text, err := collectResults(conn)
	if err != nil {
		return "", fmt.Errorf("collect results: %w", err)
	}

	return text, nil
}

func waitForEvent(conn *websocket.Conn, eventName string) error {
	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			return fmt.Errorf("read message: %w", err)
		}

		var evt serverEvent
		if err := json.Unmarshal(data, &evt); err != nil {
			return fmt.Errorf("unmarshal event: %w", err)
		}

		if evt.Header.Event == "task-failed" {
			return fmt.Errorf("task failed: %s - %s", evt.Header.ErrorCode, evt.Header.ErrorMessage)
		}

		if evt.Header.Event == eventName {
			return nil
		}
	}
}

func collectResults(conn *websocket.Conn) (string, error) {
	var sentences []string

	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			return "", fmt.Errorf("read message: %w", err)
		}

		var evt serverEvent
		if err := json.Unmarshal(data, &evt); err != nil {
			return "", fmt.Errorf("unmarshal event: %w", err)
		}

		switch evt.Header.Event {
		case "task-failed":
			return "", fmt.Errorf("task failed: %s - %s", evt.Header.ErrorCode, evt.Header.ErrorMessage)

		case "result-generated":
			s := evt.Payload.Output.Sentence
			if s != nil && s.SentenceEnd && s.Text != "" {
				sentences = append(sentences, s.Text)
			}

		case "task-finished":
			result := ""
			for _, s := range sentences {
				result += s
			}
			return result, nil
		}
	}
}
