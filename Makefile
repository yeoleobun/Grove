PLUGIN_FLAGS :=
ifneq ($(wildcard /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing),)
PLUGIN_FLAGS := -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
endif

.PHONY: build run test app open install clean

build:
	swift build

run:
	swift run Grove

test:
	swift test $(PLUGIN_FLAGS)

app:
	chmod +x scripts/build_app.sh
	./scripts/build_app.sh

open: app
	open dist/Grove.app

install: app
	rm -rf /Applications/Grove.app
	cp -R dist/Grove.app /Applications/Grove.app
	xattr -cr /Applications/Grove.app 2>/dev/null || true
	@echo "Installed to /Applications/Grove.app"

clean:
	swift package clean
	rm -rf dist
