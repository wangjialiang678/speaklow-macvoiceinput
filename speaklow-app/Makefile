APP_NAME ?= SpeakLow
BUNDLE_ID ?= com.speaklow.app
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS

SOURCES = $(wildcard Sources/*.swift)
RESOURCES = $(CONTENTS)/Resources
ARCH ?= $(shell uname -m)
ASR_BRIDGE_DIR = ../asr-bridge
ASR_BRIDGE = $(ASR_BRIDGE_DIR)/asr-bridge

ENV_FILE ?= $(HOME)/.config/speaklow/.env

.PHONY: all clean run install uninstall dist dmg

all: $(MACOS_DIR)/$(APP_NAME)

# Auto-build Go bridge binary
$(ASR_BRIDGE): $(wildcard $(ASR_BRIDGE_DIR)/*.go)
	cd "$(ASR_BRIDGE_DIR)" && go build -o asr-bridge .

$(MACOS_DIR)/$(APP_NAME): $(SOURCES) Info.plist $(ASR_BRIDGE)
	@mkdir -p "$(MACOS_DIR)" "$(RESOURCES)"
	swiftc \
		-parse-as-library \
		-o "$(MACOS_DIR)/$(APP_NAME)" \
		-sdk $$(xcrun --show-sdk-path) \
		-target $(ARCH)-apple-macosx13.0 \
		$(SOURCES)
	@cp Info.plist "$(CONTENTS)/"
	@plutil -replace CFBundleName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleDisplayName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleExecutable -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleIdentifier -string "$(BUNDLE_ID)" "$(CONTENTS)/Info.plist"
	@plutil -replace BuildDate -string "$(shell date +%Y-%m-%d)" "$(CONTENTS)/Info.plist"
	@if [ -f "$(ASR_BRIDGE)" ]; then cp "$(ASR_BRIDGE)" "$(MACOS_DIR)/asr-bridge"; echo "Copied asr-bridge"; fi
	@if [ -d Resources ] && [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(RESOURCES)/"; fi
	@if [ -f Resources/hotwords.txt ]; then cp Resources/hotwords.txt "$(RESOURCES)/"; fi
	@if [ -f Resources/refine_preamble.txt ]; then cp Resources/refine_preamble.txt "$(RESOURCES)/"; fi
	@if [ -f Resources/refine_prompt.txt ]; then cp Resources/refine_prompt.txt "$(RESOURCES)/"; fi
	@if [ -d Resources/refine_styles ]; then mkdir -p "$(RESOURCES)/refine_styles" && cp Resources/refine_styles/*.txt "$(RESOURCES)/refine_styles/"; fi
	@codesign --force --deep --sign - "$(APP_BUNDLE)"
	@echo "Ad-hoc signed $(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"

clean:
	rm -rf $(BUILD_DIR)

run: all
	@pkill -f '/SpeakLow.app/Contents/MacOS/SpeakLow' >/dev/null 2>&1 || true
	@pkill -f '/SpeakLow.app/Contents/MacOS/asr-bridge' >/dev/null 2>&1 || true
	open "$(APP_BUNDLE)"

install: clean all
	@echo "Installing to /Applications/$(APP_NAME).app ..."
	@pkill -9 -f '/SpeakLow.app/Contents/MacOS/SpeakLow' >/dev/null 2>&1 || true
	@pkill -9 -f '/SpeakLow.app/Contents/MacOS/asr-bridge' >/dev/null 2>&1 || true
	@sleep 1
	@rm -rf "/Applications/$(APP_NAME).app"
	@cp -R "$(APP_BUNDLE)" "/Applications/$(APP_NAME).app"
	@echo "Verifying binary..."
	@test -f "/Applications/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" || (echo "ERROR: binary not found!" && exit 1)
	@open "/Applications/$(APP_NAME).app"
	@sleep 1
	@pgrep -f '/Applications/SpeakLow.app/Contents/MacOS/SpeakLow' >/dev/null && echo "✓ $(APP_NAME) is running (PID $$(pgrep -f '/Applications/SpeakLow.app/Contents/MacOS/SpeakLow'))" || echo "WARNING: $(APP_NAME) failed to start"

uninstall:
	@echo "Removing /Applications/$(APP_NAME).app ..."
	@rm -rf "/Applications/$(APP_NAME).app"
	@echo "Done."

# Build a distributable zip with API key bundled inside
dist: all
	@if [ ! -f "$(ENV_FILE)" ]; then \
		echo "Error: $(ENV_FILE) not found. Set ENV_FILE to your .env path."; \
		exit 1; \
	fi
	@cp "$(ENV_FILE)" "$(MACOS_DIR)/.env"
	@echo "Bundled .env into app"
	@codesign --force --deep --sign - "$(APP_BUNDLE)"
	@echo "Ad-hoc signed"
	@cd $(BUILD_DIR) && zip -r -q "$(APP_NAME).zip" "$(APP_NAME).app"
	@echo "Created $(BUILD_DIR)/$(APP_NAME).zip — ready to share"

# Build a distributable DMG with API key bundled inside
DMG_NAME = $(APP_NAME).dmg
DMG_TEMP = $(BUILD_DIR)/dmg-staging

dmg: dist
	@echo "Creating DMG..."
	@rm -rf "$(DMG_TEMP)" "$(BUILD_DIR)/$(DMG_NAME)"
	@mkdir -p "$(DMG_TEMP)"
	@cp -R "$(APP_BUNDLE)" "$(DMG_TEMP)/"
	@ln -s /Applications "$(DMG_TEMP)/Applications"
	@hdiutil create -volname "$(APP_NAME)" \
		-srcfolder "$(DMG_TEMP)" \
		-ov -format UDZO \
		"$(BUILD_DIR)/$(DMG_NAME)"
	@rm -rf "$(DMG_TEMP)"
	@echo "Created $(BUILD_DIR)/$(DMG_NAME) — ready to share"
