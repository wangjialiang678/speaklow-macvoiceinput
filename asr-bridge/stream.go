package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/michael/audio-asr-suite/go/audio-asr-go/pkg/asr"
	"github.com/michael/audio-asr-suite/go/audio-asr-go/pkg/realtime"
)

const streamTimeout = 120 * time.Second

// Client → Bridge messages
type clientMsg struct {
	Type       string `json:"type"`                 // "start" | "audio" | "stop"
	Model      string `json:"model,omitempty"`       // only for "start"
	SampleRate int    `json:"sample_rate,omitempty"` // only for "start"
	Format     string `json:"format,omitempty"`      // only for "start"
	Data       string `json:"data,omitempty"`        // only for "audio", base64 PCM
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
			writeBridgeMsg(clientConn, nil, bridgeMsg{Type: "error", Error: "expected start message"})
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

		// 2. Create realtime module and connect to DashScope
		module, err := realtime.New(realtime.ModuleOptions{
			APIKey:     apiKey,
			Model:      model,
			SampleRate: sampleRate,
			Format:     format,
			Parameters: asr.FunASRRunTaskParameters{
				SemanticPunctuationEnabled: boolPtr(true),
				LanguageHints:              []string{"zh", "en"},
				VocabularyID:               vocabularyID,
			},
			RequestHeaders: asr.FunASRRequestHeaders{
				DataInspection: "enable",
			},
		})
		if err != nil {
			log.Printf("[stream] create module: %v", err)
			writeBridgeMsg(clientConn, nil, bridgeMsg{Type: "error", Error: fmt.Sprintf("create module: %v", err)})
			return
		}

		ctx, cancel := context.WithTimeout(context.Background(), streamTimeout)
		defer cancel()

		if err := module.Connect(ctx); err != nil {
			log.Printf("[stream] module connect: %v", err)
			writeBridgeMsg(clientConn, nil, bridgeMsg{Type: "error", Error: fmt.Sprintf("connect: %v", err)})
			return
		}
		defer module.Close(context.Background())
		log.Printf("[stream] DashScope connected")

		// 3. Subscribe to module events → forward to client
		var mu sync.Mutex
		unsubscribe := module.Subscribe(func(event realtime.Event) {
			switch event.Kind {
			case realtime.EventPartialSegment:
				if event.Segment != nil && event.Segment.Text != "" {
					writeBridgeMsg(clientConn, &mu, bridgeMsg{Type: "partial", Text: event.Segment.Text})
				}
			case realtime.EventFinalSegment:
				if event.Segment != nil && event.Segment.Text != "" {
					writeBridgeMsg(clientConn, &mu, bridgeMsg{Type: "final", Text: event.Segment.Text, SentenceEnd: true})
				}
			case realtime.EventError:
				if event.Error != nil {
					writeBridgeMsg(clientConn, &mu, bridgeMsg{Type: "error", Error: event.Error.Error()})
				}
			}
		})
		defer unsubscribe()

		// 4. Send "started" to client
		writeBridgeMsg(clientConn, &mu, bridgeMsg{Type: "started"})

		// 5. Read client messages (audio/stop) in main loop
		clientConn.SetReadDeadline(time.Now().Add(streamTimeout))

		for {
			_, raw, err := clientConn.ReadMessage()
			if err != nil {
				// Client disconnected, clean shutdown
				log.Printf("[stream] client read: %v", err)
				module.Finish(ctx)
				break
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
				if !module.SendAudioChunk(decoded) {
					log.Printf("[stream] send audio chunk failed")
				}

			case "stop":
				log.Printf("[stream] client sent stop, finishing")
				if err := module.Finish(ctx); err != nil {
					log.Printf("[stream] finish: %v", err)
					writeBridgeMsg(clientConn, &mu, bridgeMsg{Type: "error", Error: fmt.Sprintf("finish: %v", err)})
				}
				// After Finish returns, all final segments have been delivered via Subscribe
				writeBridgeMsg(clientConn, &mu, bridgeMsg{Type: "finished"})
				log.Printf("[stream] session ended normally")
				return
			}
		}
		log.Printf("[stream] session ended")
	}
}

// writeBridgeMsg sends a JSON message to the client WebSocket, protected by an optional mutex.
func writeBridgeMsg(conn *websocket.Conn, mu *sync.Mutex, msg bridgeMsg) error {
	if mu != nil {
		mu.Lock()
		defer mu.Unlock()
	}
	return conn.WriteJSON(msg)
}
