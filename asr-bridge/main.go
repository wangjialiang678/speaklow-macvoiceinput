package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	defaultPort   = "18089"
	defaultModel  = "qwen3-asr-flash-realtime"
	maxUploadSize = 50 << 20 // 50 MB
)

func initFileLog() {
	logDir := filepath.Join(os.Getenv("HOME"), "Library", "Logs")
	logPath := filepath.Join(logDir, "SpeakLow-bridge.log")

	// 简单轮转: >5MB 重命名为 .1.log
	if info, err := os.Stat(logPath); err == nil && info.Size() > 5*1024*1024 {
		_ = os.Rename(logPath, logPath+".1.log")
	}

	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		log.Printf("warning: cannot open log file %s: %v", logPath, err)
		return
	}
	log.SetOutput(io.MultiWriter(os.Stdout, f))
}

func main() {
	initFileLog()
	loadEnv()

	apiKey := os.Getenv("DASHSCOPE_API_KEY")
	if apiKey == "" {
		log.Fatal("DASHSCOPE_API_KEY is not set")
	}

	initHotwords()
	initConfigPaths()
	loadRefinePrompt()

	port := os.Getenv("ASR_BRIDGE_PORT")
	if port == "" {
		port = defaultPort
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", healthHandler)
	mux.HandleFunc("/v1/transcribe-sync", transcribeSyncHandler(apiKey))
	mux.HandleFunc("/v1/stream", streamHandler(apiKey))
	mux.HandleFunc("/v1/refine", refineHandler(apiKey))
	mux.HandleFunc("/v1/reload-hotwords", reloadHotwordsHandler)

	handler := corsMiddleware(loggingMiddleware(mux))

	addr := ":" + port
	log.Printf("asr-bridge listening on %s", addr)
	if err := http.ListenAndServe(addr, handler); err != nil {
		log.Fatalf("server error: %v", err)
	}
}

func healthHandler(w http.ResponseWriter, _ *http.Request) {
	model := os.Getenv("ASR_MODEL")
	if model == "" {
		model = defaultModel
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"status": "ok",
		"model":  model,
	})
}

func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if isAllowedOrigin(origin) {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		}

		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}

		next.ServeHTTP(w, r)
	})
}

func isAllowedOrigin(origin string) bool {
	if origin == "" {
		return false
	}
	allowed := []string{
		"http://localhost",
		"https://localhost",
		"http://127.0.0.1",
		"https://127.0.0.1",
	}
	for _, a := range allowed {
		if origin == a || strings.HasPrefix(origin, a+":") {
			return true
		}
	}
	return false
}

func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rw := &responseWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rw, r)
		log.Printf("%s %s %d %s", r.Method, r.URL.Path, rw.status, time.Since(start))
	})
}

type responseWriter struct {
	http.ResponseWriter
	status int
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.status = code
	rw.ResponseWriter.WriteHeader(code)
}

// Hijack supports WebSocket upgrade through the logging middleware.
func (rw *responseWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	if hj, ok := rw.ResponseWriter.(http.Hijacker); ok {
		return hj.Hijack()
	}
	return nil, nil, fmt.Errorf("underlying ResponseWriter does not support Hijack")
}

func reloadHotwordsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	count, err := reloadHotwords()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status": "ok",
		"words":  count,
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
