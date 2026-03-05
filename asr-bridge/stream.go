package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const (
	streamTimeout      = 120 * time.Second
	streamStartTimeout = 10 * time.Second
	dashscopeWSBaseURL = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
)

// Client -> Bridge messages
// type: start | audio | stop
// data: base64 PCM16 mono 16kHz for audio chunks
type clientMsg struct {
	Type       string `json:"type"`
	Model      string `json:"model,omitempty"`
	SampleRate int    `json:"sample_rate,omitempty"`
	Format     string `json:"format,omitempty"`
	Data       string `json:"data,omitempty"`
}

// Bridge -> Client messages
type bridgeMsg struct {
	Type        string `json:"type"` // started | partial | final | finished | error
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

		var clientWriteMu sync.Mutex

		if _, err := waitClientStart(clientConn); err != nil {
			_ = writeBridgeMsg(clientConn, &clientWriteMu, bridgeMsg{Type: "error", Error: err.Error()})
			return
		}

		dashConn, err := dialDashScopeWS(apiKey)
		if err != nil {
			_ = writeBridgeMsg(clientConn, &clientWriteMu, bridgeMsg{Type: "error", Error: fmt.Sprintf("connect dashscope: %v", err)})
			return
		}
		defer dashConn.Close()

		var dashWriteMu sync.Mutex
		if err := setupSession(clientConn, &clientWriteMu, dashConn, &dashWriteMu); err != nil {
			_ = writeBridgeMsg(clientConn, &clientWriteMu, bridgeMsg{Type: "error", Error: err.Error()})
			return
		}

		dashErrCh := make(chan error, 1)
		clientErrCh := make(chan error, 1)

		go func() {
			dashErrCh <- relayDashscopeEvents(clientConn, &clientWriteMu, dashConn)
		}()

		go func() {
			clientErrCh <- relayClientAudio(clientConn, dashConn, &dashWriteMu)
		}()

		select {
		case err := <-dashErrCh:
			if err != nil {
				log.Printf("[stream] dashscope loop ended: %v", err)
			}
			return
		case err := <-clientErrCh:
			if err != nil {
				log.Printf("[stream] client loop ended: %v", err)
				_ = dashConn.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, "client disconnected"), time.Now().Add(2*time.Second))
				return
			}
			// stop has been sent; wait for session.finished / error from DashScope.
			select {
			case err := <-dashErrCh:
				if err != nil {
					log.Printf("[stream] dashscope loop ended after stop: %v", err)
				}
			case <-time.After(15 * time.Second):
				_ = writeBridgeMsg(clientConn, &clientWriteMu, bridgeMsg{Type: "error", Error: "timeout waiting for session.finished"})
			}
			return
		}
	}
}

func waitClientStart(clientConn *websocket.Conn) (clientMsg, error) {
	clientConn.SetReadDeadline(time.Now().Add(streamStartTimeout))
	_, raw, err := clientConn.ReadMessage()
	if err != nil {
		return clientMsg{}, fmt.Errorf("read start message: %w", err)
	}

	var msg clientMsg
	if err := json.Unmarshal(raw, &msg); err != nil {
		return clientMsg{}, fmt.Errorf("invalid start message: %w", err)
	}
	if msg.Type != "start" {
		return clientMsg{}, fmt.Errorf("expected start message")
	}

	return msg, nil
}

func dialDashScopeWS(apiKey string) (*websocket.Conn, error) {
	q := url.Values{}
	q.Set("model", "qwen3-asr-flash-realtime")

	u := dashscopeWSBaseURL + "?" + q.Encode()
	headers := http.Header{}
	headers.Set("Authorization", "Bearer "+apiKey)
	headers.Set("OpenAI-Beta", "realtime=v1")

	conn, resp, err := websocket.DefaultDialer.Dial(u, headers)
	if err != nil {
		if resp != nil {
			return nil, fmt.Errorf("dial failed (%d): %w", resp.StatusCode, err)
		}
		return nil, err
	}
	return conn, nil
}

func setupSession(clientConn *websocket.Conn, clientWriteMu *sync.Mutex, dashConn *websocket.Conn, dashWriteMu *sync.Mutex) error {
	handshakeDeadline := time.Now().Add(20 * time.Second)
	updated := false

	for time.Now().Before(handshakeDeadline) {
		dashConn.SetReadDeadline(time.Now().Add(streamTimeout))
		_, raw, err := dashConn.ReadMessage()
		if err != nil {
			return fmt.Errorf("read handshake event: %w", err)
		}

		event, err := parseJSONMap(raw)
		if err != nil {
			return fmt.Errorf("parse handshake event: %w", err)
		}

		eventType := getString(event, "type")
		switch eventType {
		case "session.created":
			session := map[string]any{
				"modalities":         []string{"text"},
				"input_audio_format": "pcm",
				"sample_rate":        16000,
				"input_audio_transcription": map[string]any{
					"language": "zh",
				},
				"turn_detection": nil,
			}
			if strings.TrimSpace(qwen3Hotwords) != "" {
				session["input_audio_transcription"].(map[string]any)["corpus"] = map[string]any{
					"text": qwen3Hotwords,
				}
			}

			update := map[string]any{
				"event_id": newEventID("evt"),
				"type":     "session.update",
				"session":  session,
			}
			if err := writeDashMsg(dashConn, dashWriteMu, update); err != nil {
				return fmt.Errorf("send session.update: %w", err)
			}

		case "session.updated":
			if err := writeBridgeMsg(clientConn, clientWriteMu, bridgeMsg{Type: "started"}); err != nil {
				return fmt.Errorf("notify started: %w", err)
			}
			updated = true
			return nil

		case "error":
			return fmt.Errorf("dashscope handshake error: %s", extractDashError(event))
		}
	}

	if !updated {
		return fmt.Errorf("timeout waiting for session.updated")
	}
	return nil
}

func relayClientAudio(clientConn, dashConn *websocket.Conn, dashWriteMu *sync.Mutex) error {
	seq := 0

	for {
		clientConn.SetReadDeadline(time.Now().Add(streamTimeout))
		_, raw, err := clientConn.ReadMessage()
		if err != nil {
			if websocket.IsCloseError(err, websocket.CloseNormalClosure, websocket.CloseGoingAway) {
				return nil
			}
			return fmt.Errorf("read client message: %w", err)
		}

		var msg clientMsg
		if err := json.Unmarshal(raw, &msg); err != nil {
			continue
		}

		switch msg.Type {
		case "audio":
			if strings.TrimSpace(msg.Data) == "" {
				continue
			}
			pcm, err := base64.StdEncoding.DecodeString(msg.Data)
			if err != nil {
				continue
			}
			payload := map[string]any{
				"event_id": newEventID(fmt.Sprintf("audio_%d", seq)),
				"type":     "input_audio_buffer.append",
				"audio":    base64.StdEncoding.EncodeToString(pcm),
			}
			seq++
			if err := writeDashMsg(dashConn, dashWriteMu, payload); err != nil {
				return fmt.Errorf("append audio: %w", err)
			}

		case "stop":
			if err := writeDashMsg(dashConn, dashWriteMu, map[string]any{"type": "input_audio_buffer.commit"}); err != nil {
				return fmt.Errorf("commit audio: %w", err)
			}
			if err := writeDashMsg(dashConn, dashWriteMu, map[string]any{"type": "session.finish"}); err != nil {
				return fmt.Errorf("finish session: %w", err)
			}
			return nil
		}
	}
}

func relayDashscopeEvents(clientConn *websocket.Conn, clientWriteMu *sync.Mutex, dashConn *websocket.Conn) error {
	for {
		dashConn.SetReadDeadline(time.Now().Add(streamTimeout))
		_, raw, err := dashConn.ReadMessage()
		if err != nil {
			if websocket.IsCloseError(err, websocket.CloseNormalClosure, websocket.CloseGoingAway) {
				return nil
			}
			return fmt.Errorf("read dashscope event: %w", err)
		}

		event, err := parseJSONMap(raw)
		if err != nil {
			continue
		}

		eventType := getString(event, "type")
		switch eventType {
		case "conversation.item.input_audio_transcription.text":
			transcript := strings.TrimSpace(getString(event, "transcript"))
			if transcript != "" {
				if err := writeBridgeMsg(clientConn, clientWriteMu, bridgeMsg{Type: "partial", Text: transcript}); err != nil {
					return fmt.Errorf("write partial: %w", err)
				}
			}

		case "conversation.item.input_audio_transcription.completed":
			transcript := strings.TrimSpace(getString(event, "transcript"))
			if transcript != "" {
				if err := writeBridgeMsg(clientConn, clientWriteMu, bridgeMsg{Type: "final", Text: transcript, SentenceEnd: true}); err != nil {
					return fmt.Errorf("write final: %w", err)
				}
			}

		case "session.finished":
			if err := writeBridgeMsg(clientConn, clientWriteMu, bridgeMsg{Type: "finished"}); err != nil {
				return fmt.Errorf("write finished: %w", err)
			}
			return nil

		case "error":
			errMsg := extractDashError(event)
			if err := writeBridgeMsg(clientConn, clientWriteMu, bridgeMsg{Type: "error", Error: errMsg}); err != nil {
				return fmt.Errorf("write error message: %w", err)
			}
			return fmt.Errorf("dashscope error: %s", errMsg)
		}
	}
}

func parseJSONMap(raw []byte) (map[string]any, error) {
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, err
	}
	return m, nil
}

func getString(m map[string]any, key string) string {
	if v, ok := m[key]; ok {
		if s, ok := v.(string); ok {
			return s
		}
	}
	return ""
}

func extractDashError(event map[string]any) string {
	if errVal, ok := event["error"]; ok {
		switch v := errVal.(type) {
		case string:
			if strings.TrimSpace(v) != "" {
				return v
			}
		case map[string]any:
			if msg := getString(v, "message"); msg != "" {
				return msg
			}
			if msg := getString(v, "code"); msg != "" {
				return msg
			}
		}
	}
	if msg := getString(event, "message"); msg != "" {
		return msg
	}
	return "unknown error"
}

func newEventID(prefix string) string {
	return fmt.Sprintf("%s_%d", prefix, time.Now().UnixMilli())
}

// writeBridgeMsg sends a JSON message to the client WebSocket, protected by an optional mutex.
func writeBridgeMsg(conn *websocket.Conn, mu *sync.Mutex, msg bridgeMsg) error {
	if mu != nil {
		mu.Lock()
		defer mu.Unlock()
	}
	conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	return conn.WriteJSON(msg)
}

func writeDashMsg(conn *websocket.Conn, mu *sync.Mutex, payload map[string]any) error {
	if mu != nil {
		mu.Lock()
		defer mu.Unlock()
	}
	conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	return conn.WriteJSON(payload)
}
