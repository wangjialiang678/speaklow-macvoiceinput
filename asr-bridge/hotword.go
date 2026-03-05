package main

import (
	"context"
	"crypto/sha256"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
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

	cachedID := loadCachedVocabularyID()
	currentHash, hashErr := computeFileHash(hotwordsPath)
	cachedHash := loadCachedHash()

	if cachedID != "" && hashErr == nil && currentHash == cachedHash {
		vocabularyID = cachedID
		log.Printf("[hotword] reusing cached vocabularyID=%s (hotwords unchanged)", vocabularyID)
		return
	}

	manager, err := hotword.NewManager(hotword.ManagerOptions{
		APIKey: apiKey,
	})
	if err != nil {
		if cachedID != "" {
			vocabularyID = cachedID
			log.Printf("[hotword] manager init failed (%v), using cached vocabularyID=%s", err, vocabularyID)
		} else {
			log.Printf("[hotword] create manager failed: %v, no cache available", err)
		}
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
			saveCachedVocabularyID(vocabularyID)
			if hashErr == nil {
				saveCachedHash(currentHash)
			}
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
	saveCachedVocabularyID(vocabularyID)
	if hashErr == nil {
		saveCachedHash(currentHash)
	}
}

func vocabularyIDCachePath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "speaklow", "vocabulary_id")
}

func loadCachedVocabularyID() string {
	data, err := os.ReadFile(vocabularyIDCachePath())
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

func saveCachedVocabularyID(id string) {
	path := vocabularyIDCachePath()
	_ = os.MkdirAll(filepath.Dir(path), 0o755)
	_ = os.WriteFile(path, []byte(id), 0o600)
}

func hotwordsHashCachePath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "speaklow", "hotwords_hash")
}

func computeFileHash(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(data)
	return fmt.Sprintf("%x", sum), nil
}

func loadCachedHash() string {
	data, err := os.ReadFile(hotwordsHashCachePath())
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

func saveCachedHash(hash string) {
	path := hotwordsHashCachePath()
	_ = os.MkdirAll(filepath.Dir(path), 0o755)
	_ = os.WriteFile(path, []byte(hash), 0o600)
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
