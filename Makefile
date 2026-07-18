# Build and install 'md'
#
# Dependencies md4c, tree-sitter, grammars are managed with build.zig.zon

# zig build -p <prefix> installs into <prefix>/bin/md
#

PREFIX ?= $(HOME)/.local

.PHONY: build install test regen-assets clean

build:
	zig build --release=safe

install:
	zig build --release=safe -p $(PREFIX)

test:
	zig build test

regen-assets:
	./tools/regen-assets.sh

clean:
	rm -rf zig-out .zig-cache

