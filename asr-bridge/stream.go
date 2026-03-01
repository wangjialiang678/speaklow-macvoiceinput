package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const streamTimeout = 120 * time.Second

// Client → Bridge messages
type clientMsg struct {
	Type       string `json:"type"`                   // "start" | "audio" | "stop"
	Model      string `json:"model,omitempty"`         // only for "start"
	SampleRate int    `json:"sample_rate,omitempty"`   // only for "start"
	Format     string `json:"format,omitempty"`        // only for "start"
	Data       string `json:"data,omitempty"`          // only for "audio", base64 PCM
}

// Bridge → Client messages
type bridgeMsg struct {
	Type        string `json:"type"`                    // "started" | "partial" | "final" | "finished" | "error"
	Text        string `json:"text,omitempty"`
	SentenceEnd bool   `json:"sentence_end,omitempty"`
	Error       string `json:"error,omitempty"`
}

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool {
		origin := r.Header.Get("Origin")
		return origin == "" || isAllowedOrigin(origin)
	},
}

func streamHandler(apiKey string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		clientConn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			log.Printf("[stream] upgrade error: %v", err)
			return
		}
		defer clientConn.Close()
		log.Printf("[stream] client connected")

		// 1. Wait for "start" message from client
		clientConn.SetReadDeadline(time.Now().Add(10 * time.Second))
		_, raw, err := clientConn.ReadMessage()
		if err != nil {
			log.Printf("[stream] read start message: %v", err)
			return
		}

		var startMsg clientMsg
		if err := json.Unmarshal(raw, &startMsg); err != nil || startMsg.Type != "start" {
			sendBridgeMsg(clientConn, bridgeMsg{Type: "error", Error: "expected start message"})
			return
		}

		model := startMsg.Model
		if model == "" {
			model = os.Getenv("ASR_MODEL")
		}
		if model == "" {
			model = defaultModel
		}
		sampleRate := startMsg.SampleRate
		if sampleRate <= 0 {
			sampleRate = defaultSampleRate
		}
		format := startMsg.Format
		if format == "" {
			format = "pcm"
		}

		// 2. Connect to DashScope
		dashConn, taskID, err := connectDashScope(apiKey, model, format, sampleRate)
		if err != nil {
			log.Printf("[stream] DashScope connect failed: %v", err)
			sendBridgeMsg(clientConn, bridgeMsg{Type: "error", Error: fmt.Sprintf("DashScope connect: %v", err)})
			return
		}
		defer dashConn.Close()
		log.Printf("[stream] DashScope connected, taskID=%s", taskID)

		// Set streaming timeout
		deadline := time.Now().Add(streamTimeout)
		dashConn.SetReadDeadline(deadline)
		clientConn.SetReadDeadline(deadline)

		// 3. Reply "started" to client
		if err := sendBridgeMsg(clientConn, bridgeMsg{Type: "started"}); err != nil {
			log.Printf("[stream] send started: %v", err)
			return
		}

		// 4. Launch goroutines for three-way relay
		//    - dashReader: DashScope → resultCh
		//    - clientReader: Swift → audioCh / stopCh
		//    - main: multiplex channels, write to both connections

		type audioChunk struct {
			data []byte
		}
		type dashResult struct {
			msg bridgeMsg
			err error
		}

		audioCh := make(chan audioChunk, 64)
		stopCh := make(chan struct{}, 1)
		resultCh := make(chan dashResult, 64)
		doneCh := make(chan struct{})

		var wg sync.WaitGroup

		// DashScope reader goroutine
		wg.Add(1)
		go func() {
			defer wg.Done()
			defer close(resultCh)
			for {
				_, data, err := dashConn.ReadMessage()
				if err != nil {
					select {
					case <-doneCh:
						return
					default:
					}
					resultCh <- dashResult{err: fmt.Errorf("dash read: %w", err)}
					return
				}

				var evt serverEvent
				if err := json.Unmarshal(data, &evt); err != nil {
					resultCh <- dashResult{err: fmt.Errorf("dash unmarshal: %w", err)}
					return
				}

				switch evt.Header.Event {
				case "task-failed":
					resultCh <- dashResult{msg: bridgeMsg{
						Type:  "error",
						Error: fmt.Sprintf("%s: %s", evt.Header.ErrorCode, evt.Header.ErrorMessage),
					}}
					return

				case "result-generated":
					s := evt.Payload.Output.Sentence
					if s == nil || s.Text == "" {
						continue
					}
					if s.SentenceEnd {
						resultCh <- dashResult{msg: bridgeMsg{Type: "final", Text: s.Text, SentenceEnd: true}}
					} else {
						resultCh <- dashResult{msg: bridgeMsg{Type: "partial", Text: s.Text}}
					}

				case "task-finished":
					resultCh <- dashResult{msg: bridgeMsg{Type: "finished"}}
					return
				}
			}
		}()

		// Client reader goroutine
		wg.Add(1)
		go func() {
			defer wg.Done()
			defer close(audioCh)
			for {
				_, raw, err := clientConn.ReadMessage()
				if err != nil {
					select {
					case <-doneCh:
						return
					default:
					}
					log.Printf("[stream] client read: %v", err)
					return
				}

				var msg clientMsg
				if err := json.Unmarshal(raw, &msg); err != nil {
					log.Printf("[stream] client unmarshal: %v", err)
					continue
				}

				switch msg.Type {
				case "audio":
					decoded, err := base64.StdEncoding.DecodeString(msg.Data)
					if err != nil {
						log.Printf("[stream] base64 decode: %v", err)
						continue
					}
					select {
					case audioCh <- audioChunk{data: decoded}:
					case <-doneCh:
						return
					}

				case "stop":
					select {
					case stopCh <- struct{}{}:
					default:
					}
					return
				}
			}
		}()

		// Main goroutine: multiplex
		finishSent := false
		finished := false

		for !finished {
			select {
			case chunk, ok := <-audioCh:
				if !ok {
					// Client disconnected without sending stop
					if !finishSent {
						sendFinishTask(dashConn, taskID)
						finishSent = true
					}
					audioCh = nil
					continue
				}
				// Forward audio to DashScope
				if err := dashConn.WriteMessage(websocket.BinaryMessage, chunk.data); err != nil {
					log.Printf("[stream] dash write audio: %v", err)
					sendBridgeMsg(clientConn, bridgeMsg{Type: "error", Error: "dash audio write failed"})
					finished = true
				}

			case <-stopCh:
				// Client says recording done
				log.Printf("[stream] client sent stop, sending finish-task")
				if !finishSent {
					if err := sendFinishTask(dashConn, taskID); err != nil {
						log.Printf("[stream] send finish-task: %v", err)
						sendBridgeMsg(clientConn, bridgeMsg{Type: "error", Error: "finish-task failed"})
						finished = true
					}
					finishSent = true
				}

			case result, ok := <-resultCh:
				if !ok {
					// DashScope reader closed
					finished = true
					continue
				}
				if result.err != nil {
					log.Printf("[stream] dash error: %v", result.err)
					sendBridgeMsg(clientConn, bridgeMsg{Type: "error", Error: result.err.Error()})
					finished = true
					continue
				}
				// Forward result to client
				if err := sendBridgeMsg(clientConn, result.msg); err != nil {
					log.Printf("[stream] send to client: %v", err)
					finished = true
					continue
				}
				if result.msg.Type == "finished" {
					finished = true
				}
			}
		}

		close(doneCh)
		wg.Wait()
		log.Printf("[stream] session ended")
	}
}

// connectDashScope establishes WebSocket to DashScope, sends run-task,
// waits for task-started, and returns the connection ready for audio.
func connectDashScope(apiKey, model, format string, sampleRate int) (*websocket.Conn, string, error) {
	taskID, err := randomTaskID()
	if err != nil {
		return nil, "", fmt.Errorf("generate task id: %w", err)
	}

	dialer := websocket.Dialer{
		HandshakeTimeout: dialTimeout,
	}

	headers := http.Header{
		"Authorization":              []string{"bearer " + apiKey},
		"X-DashScope-DataInspection": []string{"enable"},
	}

	conn, _, err := dialer.Dial(dashscopeWSURL, headers)
	if err != nil {
		return nil, "", fmt.Errorf("websocket dial: %w", err)
	}

	// Set initial deadline for handshake phase
	conn.SetReadDeadline(time.Now().Add(dialTimeout))
	conn.SetWriteDeadline(time.Now().Add(dialTimeout))

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
		conn.Close()
		return nil, "", fmt.Errorf("send run-task: %w", err)
	}

	if err := waitForEvent(conn, "task-started"); err != nil {
		conn.Close()
		return nil, "", fmt.Errorf("wait task-started: %w", err)
	}

	return conn, taskID, nil
}

// sendFinishTask sends the finish-task message to DashScope.
func sendFinishTask(dashConn *websocket.Conn, taskID string) error {
	msg := finishTaskMsg{
		Header: finishTaskHeader{
			Action:    "finish-task",
			TaskID:    taskID,
			Streaming: "duplex",
		},
		Payload: finishTaskPayload{
			Input: map[string]any{},
		},
	}
	return dashConn.WriteJSON(msg)
}

func sendBridgeMsg(conn *websocket.Conn, msg bridgeMsg) error {
	return conn.WriteJSON(msg)
}
