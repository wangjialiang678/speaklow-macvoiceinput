APP_NAME ?= SpeakLow
BUNDLE_ID ?= com.speaklow.app
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS

SOURCES = $(wildcard Sources/*.swift)
RESOURCES = $(CONTENTS)/Resources
ARCH ?= $(shell uname -m)
ASR_BRIDGE = ../asr-bridge/asr-bridge

ENV_FILE ?= $(HOME)/.config/speaklow/.env

.PHONY: all clean run install uninstall dist

all: $(MACOS_DIR)/$(APP_NAME)

$(MACOS_DIR)/$(APP_NAME): $(SOURCES) Info.plist
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
	@if [ -f "$(ASR_BRIDGE)" ]; then cp "$(ASR_BRIDGE)" "$(MACOS_DIR)/asr-bridge"; echo "Copied asr-bridge"; fi
	@if [ -d Resources ] && [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(RESOURCES)/"; fi
	@if [ -f Resources/hotwords.txt ]; then cp Resources/hotwords.txt "$(RESOURCES)/"; fi
	@echo "Built $(APP_BUNDLE)"

clean:
	rm -rf $(BUILD_DIR)

run: all
	open "$(APP_BUNDLE)"

install: all
	@echo "Installing to /Applications/$(APP_NAME).app ..."
	@cp -R "$(APP_BUNDLE)" "/Applications/$(APP_NAME).app"
	@echo "Done. You can now launch $(APP_NAME) from Launchpad."

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
