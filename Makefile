V ?= v
UI2_SOURCE ?= $(HOME)/.vmodules/ui2
APP_REPO ?= vlang/v
APP_INSTALL_DIR ?= $(HOME)/Applications
GHUI_MODULE_PATH := $(CURDIR)/.build/vmodules|@vlib|@vmodules
GHUI_MODULE_SEPARATOR := $(if $(filter Windows_NT,$(OS)),;,:)
GHUI_VMODULES := $(CURDIR)/.build/vmodules$(GHUI_MODULE_SEPARATOR)$(if $(VMODULES),$(VMODULES),$(HOME)/.vmodules)

.PHONY: all prod app install install-links uninstall-links test test-native fmt clean custom prepare-ui2
all: prepare-ui2
	$(V) -path '$(GHUI_MODULE_PATH)' -o ghgui .

prod: prepare-ui2
	$(V) -path '$(GHUI_MODULE_PATH)' -prod -o ghui .

.build/AppIcon.icns: packaging/macos/AppIcon.png scripts/build-app-icon.sh
	sh scripts/build-app-icon.sh packaging/macos/AppIcon.png $@

app: prod .build/AppIcon.icns
	mkdir -p Github.app/Contents/MacOS Github.app/Contents/Resources
	# Fresh files avoid macOS retaining cached signatures of overwritten executables.
	sh scripts/install-app-executable.sh ghui Github.app/Contents/MacOS/ghui
	sh scripts/install-app-executable.sh scripts/app-launcher.sh Github.app/Contents/MacOS/Github
	cp packaging/macos/Info.plist Github.app/Contents/Info.plist
	cp .build/AppIcon.icns Github.app/Contents/Resources/AppIcon.icns
	printf '%s\n' '$(APP_REPO)' > Github.app/Contents/Resources/default-repository
	printf 'APPL????' > Github.app/Contents/PkgInfo
	plutil -lint Github.app/Contents/Info.plist
	touch Github.app
	mkdir -p 'Github Links.app/Contents/MacOS'
	clang -fobjc-arc -O2 -framework Cocoa -framework CoreServices packaging/macos/link-router.m -o .build/ghui-links
	sh scripts/install-app-executable.sh .build/ghui-links 'Github Links.app/Contents/MacOS/Github Links'
	cp packaging/macos/LinkRouter-Info.plist 'Github Links.app/Contents/Info.plist'
	plutil -lint 'Github Links.app/Contents/Info.plist'

install: app
	mkdir -p '$(APP_INSTALL_DIR)/Github.app/Contents/MacOS' '$(APP_INSTALL_DIR)/Github.app/Contents/Resources'
	# Replace executable inodes safely while an older instance is running.
	sh scripts/install-app-executable.sh ghui '$(APP_INSTALL_DIR)/Github.app/Contents/MacOS/ghui'
	sh scripts/install-app-executable.sh scripts/app-launcher.sh '$(APP_INSTALL_DIR)/Github.app/Contents/MacOS/Github'
	cp Github.app/Contents/Info.plist '$(APP_INSTALL_DIR)/Github.app/Contents/Info.plist'
	cp Github.app/Contents/PkgInfo '$(APP_INSTALL_DIR)/Github.app/Contents/PkgInfo'
	ditto Github.app/Contents/Resources '$(APP_INSTALL_DIR)/Github.app/Contents/Resources'
	touch '$(APP_INSTALL_DIR)/Github.app'

install-links: install
	mkdir -p '$(APP_INSTALL_DIR)/Github Links.app/Contents/MacOS'
	sh scripts/install-app-executable.sh .build/ghui-links '$(APP_INSTALL_DIR)/Github Links.app/Contents/MacOS/Github Links'
	cp 'Github Links.app/Contents/Info.plist' '$(APP_INSTALL_DIR)/Github Links.app/Contents/Info.plist'
	'$(APP_INSTALL_DIR)/Github Links.app/Contents/MacOS/Github Links' --install '$(APP_INSTALL_DIR)/Github.app'

uninstall-links:
	'$(APP_INSTALL_DIR)/Github Links.app/Contents/MacOS/Github Links' --uninstall

custom: prepare-ui2
	$(V) -path '$(GHUI_MODULE_PATH)' -d ui2_custom_rendering -o ghgui .

test: prepare-ui2
	VMODULES='$(GHUI_VMODULES)' $(V) test $(wildcard *_test.v)

test-native: prepare-ui2
	$(V) -path '$(GHUI_MODULE_PATH)' run scripts/markdown-native-check.v

prepare-ui2:
	sh scripts/prepare-ui2.sh '$(UI2_SOURCE)' '$(CURDIR)/.build/vmodules/ui2'

fmt:
	$(V) fmt -w $(wildcard *.v scripts/*.v)

clean:
	rm -f ghgui ghgui.exe ghui ghui.exe
	rm -rf Github.app
	rm -rf 'Github Links.app'
