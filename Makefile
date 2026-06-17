.PHONY: setup generate build install uninstall clean test open lint app app-install

SCHEME     = PowerSleuth
BUILD_DIR  = .build
APP_NAME   = PowerSleuth.app
APP_DEST   = /Applications/$(APP_NAME)

# Build the .app WITHOUT Xcode — Command Line Tools only (Swift Package Manager).
# This is the easiest way to build on a Mac that doesn't have Xcode installed.
app:
	./scripts/build.sh

app-install:
	./scripts/build.sh --install

setup:
	@echo "Installing dependencies..."
	@which xcodegen > /dev/null || brew install xcodegen
	@which swiftformat > /dev/null || brew install swiftformat

generate:
	@echo "Generating Xcode project..."
	xcodegen generate

build: generate
	xcodebuild -scheme $(SCHEME) \
	  -configuration Release \
	  -derivedDataPath $(BUILD_DIR) \
	  CODE_SIGN_IDENTITY="-" \
	  CODE_SIGNING_REQUIRED=NO \
	  | xcpretty 2>/dev/null || cat

install: build
	@echo "Installing to /Applications..."
	cp -r "$(BUILD_DIR)/Build/Products/Release/$(APP_NAME)" "$(APP_DEST)"
	@echo "Done! Open PowerSleuth from /Applications or Spotlight."

uninstall:
	@echo "Removing /Applications/$(APP_NAME)..."
	rm -rf "$(APP_DEST)"

clean:
	rm -rf $(BUILD_DIR)
	rm -rf PowerSleuth.xcodeproj

test: generate
	xcodebuild test \
	  -scheme $(SCHEME) \
	  -destination 'platform=macOS' \
	  CODE_SIGN_IDENTITY="-" \
	  CODE_SIGNING_REQUIRED=NO \
	  | xcpretty 2>/dev/null || cat

lint:
	swiftformat --lint PowerSleuth/ PowerSleuthTests/

format:
	swiftformat PowerSleuth/ PowerSleuthTests/

open: generate
	open PowerSleuth.xcodeproj
