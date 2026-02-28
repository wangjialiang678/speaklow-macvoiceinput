package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"
)

const (
	defaultPort      = "18089"
	defaultModel     = "paraformer-realtime-v2"
	defaultSampleRate = 16000
	defaultFormat    = "wav"
	maxUploadSize    = 50 << 20 // 50 MB
)

func main() {
	loadEnv()

	apiKey := os.Getenv("DASHSCOPE_API_KEY")
	if apiKey == "" {
		log.Fatal("DASHSCOPE_API_KEY is not set")
	}

	port := os.Getenv("ASR_BRIDGE_PORT")
	if port == "" {
		port = defaultPort
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", healthHandler)
	mux.HandleFunc("/v1/transcribe", transcribeHandler(apiKey))

	handler := corsMiddleware(loggingMiddleware(mux))

	addr := ":" + port
	log.Printf("asr-bridge listening on %s", addr)
	if err := http.ListenAndServe(addr, handler); err != nil {
		log.Fatalf("server error: %v", err)
	}
}

func healthHandler(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func transcribeHandler(apiKey string) http.HandlerFunc {
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

		model := r.FormValue("model")
		if model == "" {
			model = os.Getenv("ASR_MODEL")
		}
		if model == "" {
			model = defaultModel
		}

		sampleRate := defaultSampleRate
		if s := r.FormValue("sample_rate"); s != "" {
			if v, err := strconv.Atoi(s); err == nil && v > 0 {
				sampleRate = v
			}
		}

		format := r.FormValue("format")
		if format == "" {
			format = defaultFormat
		}

		start := time.Now()
		text, err := transcribe(apiKey, audioData, model, sampleRate, format)
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
	for _, prefix := range allowed {
		if len(origin) >= len(prefix) && origin[:len(prefix)] == prefix {
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

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
