module speaklow/asr-bridge

go 1.22.0

require (
	github.com/gorilla/websocket v1.5.3
	github.com/joho/godotenv v1.5.1
	github.com/michael/audio-asr-suite/go/audio-asr-go v0.0.0-00010101000000-000000000000
)

replace github.com/michael/audio-asr-suite/go/audio-asr-go => ../../../组件模块/audio-asr-suite/go/audio-asr-go
