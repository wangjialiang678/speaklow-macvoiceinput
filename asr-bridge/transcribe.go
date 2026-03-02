package main

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/michael/audio-asr-suite/go/audio-asr-go/pkg/asr"
	"github.com/michael/audio-asr-suite/go/audio-asr-go/pkg/realtime"
)

const (
	transcribeTimeout = 30 * time.Second
	chunkSize         = 3200
)

// transcribe sends audio data to DashScope FunASR and returns the recognized text.
func transcribe(apiKey string, audioData []byte, model string, sampleRate int, format string) (string, error) {
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
		return "", fmt.Errorf("create realtime module: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), transcribeTimeout)
	defer cancel()

	if err := module.Connect(ctx); err != nil {
		return "", classifyAndWrap("connect", err)
	}
	defer module.Close(context.Background())

	for offset := 0; offset < len(audioData); offset += chunkSize {
		end := offset + chunkSize
		if end > len(audioData) {
			end = len(audioData)
		}
		if !module.SendAudioChunk(audioData[offset:end]) {
			return "", fmt.Errorf("send audio chunk at offset %d failed", offset)
		}
	}

	if err := module.Finish(ctx); err != nil {
		return "", classifyAndWrap("finish", err)
	}

	result := module.BuildResult("zh")
	return result.Text, nil
}

func boolPtr(v bool) *bool { return &v }

func classifyAndWrap(phase string, err error) error {
	var asrErr *asr.Error
	if errors.As(err, &asrErr) {
		return fmt.Errorf("%s: [%s] %s", phase, asrErr.Code, asrErr.Message)
	}
	return fmt.Errorf("%s: %w", phase, err)
}
