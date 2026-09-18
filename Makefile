PREFIX ?= /usr/local
BIN    := spacejump
LABEL  := com.spacejump.daemon
PLIST  := $(HOME)/Library/LaunchAgents/$(LABEL).plist

CFLAGS := -fobjc-arc -fmodules -Wall -Wextra -Wno-unused-parameter -O2
FRAMEWORKS := -framework AppKit -framework Carbon -framework Foundation

.PHONY: all clean install uninstall load unload reload

all: $(BIN)

$(BIN): spacejump.m
	clang $(CFLAGS) $(FRAMEWORKS) -o $@ $<

clean:
	rm -f $(BIN)

install: $(BIN)
	install -d $(PREFIX)/bin
	# Replace the file rather than writing through it: overwriting a running
	# binary's inode in place will crash the live daemon.
	rm -f $(PREFIX)/bin/$(BIN)
	install -m 0755 $(BIN) $(PREFIX)/bin/$(BIN)
	@echo "installed $(PREFIX)/bin/$(BIN)"
	@echo "next: $(BIN) init  &&  make load"

uninstall: unload
	rm -f $(PREFIX)/bin/$(BIN)

load: $(PLIST)
	launchctl bootstrap gui/$$(id -u) $(PLIST) 2>/dev/null || \
	launchctl load -w $(PLIST)
	@echo "daemon loaded; log at /tmp/$(LABEL).log"

unload:
	-launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || \
	 launchctl unload -w $(PLIST) 2>/dev/null
	@true

# Re-read the config without restarting.
reload:
	@pkill -HUP -x $(BIN) && echo "reload signalled" || echo "daemon not running"

$(PLIST): launchagent.plist.in
	install -d $(dir $(PLIST))
	sed -e 's|@LABEL@|$(LABEL)|g' -e 's|@BIN@|$(PREFIX)/bin/$(BIN)|g' $< > $@
	@echo "wrote $(PLIST)"
