package main

import (
	"context"
	"log"
	"os"
	"path/filepath"
	"time"

	"github.com/michael/audio-asr-suite/go/audio-asr-go/pkg/hotword"
)

// vocabularyID is set during startup and read by transcribe/stream handlers.
// Empty string means no hotwords configured (ASR still works, just without vocabulary biasing).
var vocabularyID string

func initHotwords(apiKey string) {
	hotwordsPath := findHotwordsFile()
	if hotwordsPath == "" {
		log.Println("[hotword] hotwords.txt not found, skipping vocabulary init")
		return
	}
	log.Printf("[hotword] found hotwords.txt at %s", hotwordsPath)

	manager, err := hotword.NewManager(hotword.ManagerOptions{
		APIKey: apiKey,
	})
	if err != nil {
		log.Printf("[hotword] create manager failed: %v", err)
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	// Try to reuse existing table with "speaklow" prefix
	tables, err := manager.ListHotwordTables(ctx, hotword.ListTablesRequest{
		Prefix: "speaklow",
	})
	if err != nil {
		log.Printf("[hotword] list tables failed: %v, will try creating new", err)
	}

	if len(tables) > 0 {
		vocabularyID = tables[0].VocabularyID
		log.Printf("[hotword] reusing existing table: %s", vocabularyID)
		if _, err := manager.ReplaceHotwordsFromTextFile(ctx, vocabularyID, hotwordsPath); err != nil {
			log.Printf("[hotword] replace hotwords failed: %v (keeping old words)", err)
		} else {
			log.Printf("[hotword] updated hotwords in table %s", vocabularyID)
		}
		return
	}

	// Create new table
	words, err := loadHotwordsFromFile(hotwordsPath)
	if err != nil {
		log.Printf("[hotword] parse hotwords file failed: %v", err)
		return
	}
	table, err := manager.CreateHotwordTable(ctx, hotword.CreateTableRequest{
		Prefix:      "speaklow",
		TargetModel: "paraformer-realtime-v2",
		Words:       words,
	})
	if err != nil {
		log.Printf("[hotword] create table failed: %v", err)
		return
	}
	vocabularyID = table.VocabularyID
	log.Printf("[hotword] created new table: %s (%d words)", vocabularyID, len(words))
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

func loadHotwordsFromFile(path string) ([]hotword.Entry, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return hotword.ParseText(string(content))
}
