package main

import (
	"bufio"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
)

// qwen3Hotwords is the corpus.text for qwen3 realtime ASR (loaded from hotwords.txt at startup)
var qwen3Hotwords string

func initHotwords() {
	path := findHotwordsFile()
	if path == "" {
		log.Println("[hotword] hotwords.txt not found, skipping")
		return
	}
	log.Printf("[hotword] loading hotwords from %s", path)

	qwen3Hotwords = buildCorpusText(path)
	if qwen3Hotwords != "" {
		log.Printf("[hotword] corpus.text loaded (%d chars)", len(qwen3Hotwords))
	}
}

func buildCorpusText(path string) string {
	f, err := os.Open(path)
	if err != nil {
		log.Printf("[hotword] open file: %v", err)
		return ""
	}
	defer f.Close()

	var words []string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		fields := strings.Split(line, "\t")
		if len(fields) == 0 {
			continue
		}

		word := fields[0]
		// 第5列是音近提示（可选）
		if len(fields) >= 5 && strings.TrimSpace(fields[4]) != "" {
			word = fmt.Sprintf("%s（%s）", fields[0], strings.TrimSpace(fields[4]))
		}
		words = append(words, word)
	}
	if err := scanner.Err(); err != nil {
		log.Printf("[hotword] scan file: %v", err)
		return ""
	}

	if len(words) == 0 {
		return ""
	}

	header := "本次对话涉及 AI 开发技术，以下专有名词可能出现\n（括号内为中文音近说法，听到时请输出英文原文）：\n"
	return header + strings.Join(words, ", ")
}

func findHotwordsFile() string {
	// Env override
	if p := os.Getenv("HOTWORDS_FILE"); p != "" {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}

	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	exeDir := filepath.Dir(exe)

	candidates := []string{
		// App bundle: Contents/MacOS/asr-bridge → Contents/Resources/hotwords.txt
		filepath.Join(exeDir, "..", "Resources", "hotwords.txt"),
		// Dev: asr-bridge/asr-bridge → speaklow-app/Resources/hotwords.txt
		filepath.Join(exeDir, "..", "speaklow-app", "Resources", "hotwords.txt"),
	}

	for _, p := range candidates {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return ""
}
