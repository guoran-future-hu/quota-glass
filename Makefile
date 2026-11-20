# make            编译到 build/RateLimits
# make preview    用缓存离屏渲染 build/preview.png（不取数、不开窗）
# make json       取一次数打 JSON
# make install    装进 ~/Applications/RateLimits.app 并重启
# make autostart  登录自启（写 LaunchAgent，下次登录生效）

APP     := $(HOME)/Applications/RateLimits.app
BIN     := build/RateLimits
SOURCES := $(wildcard Sources/*.swift)

$(BIN): $(SOURCES)
	@mkdir -p build
	swiftc -O -framework AppKit -o $@ $(SOURCES)

preview: $(BIN)
	./$(BIN) --preview build/preview.png

json: $(BIN)
	./$(BIN) --json

install: $(BIN)
	-pkill -f "$(APP)/Contents/MacOS/RateLimits"
	mkdir -p "$(APP)/Contents/MacOS"
	cp Info.plist "$(APP)/Contents/Info.plist"
	cp $(BIN) "$(APP)/Contents/MacOS/RateLimits"
	codesign --force --deep -s - "$(APP)"
	open -a "$(APP)"

AGENT := $(HOME)/Library/LaunchAgents/ai.local.ratelimits.plist

autostart:
	mkdir -p "$(dir $(AGENT))"
	sed "s|@BINARY@|$(APP)/Contents/MacOS/RateLimits|" LaunchAgent.plist > "$(AGENT)"
	@echo "已写 $(AGENT)，下次登录生效"

.PHONY: preview json install autostart
