.PHONY: build test bundle install run clean

CODESIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development/{print $$2; exit}')
VERSION ?= 0.1.0
BUILD ?= 1
CODESIGN_OPTS ?=
APP_BUNDLE := dist/CodexBar.app

build:
	swift build -c release

test:
	swift test

bundle: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	cp .build/release/CodexBar $(APP_BUNDLE)/Contents/MacOS/
	cp Packaging/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	cp Packaging/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/
	/usr/libexec/PlistBuddy \
		-c "Set :CFBundleShortVersionString $(VERSION)" \
		-c "Set :CFBundleVersion $(BUILD)" \
		$(APP_BUNDLE)/Contents/Info.plist
	IDENT="$(CODESIGN_IDENTITY)"; [ -n "$$IDENT" ] || IDENT="-"; \
	codesign --force --sign "$$IDENT" --identifier com.gordonbeeming.CodexBar $(CODESIGN_OPTS) $(APP_BUNDLE)

install: bundle
	pkill -f "$$HOME/Applications/CodexBar.app/Contents/MacOS/CodexBar" || true
	ditto $(APP_BUNDLE) ~/Applications/CodexBar.app

run:
	swift run

clean:
	rm -rf .build dist
