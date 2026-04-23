# auto_claude helper binary — build / install / cross-compile.
#
# Local install (default):
#   make install                 # builds for host and copies to $(PREFIX)/bin
#
# Cross-compile for release (darwin + linux, arm64 + amd64):
#   make build-all               # outputs to dist/ac-helper-<os>-<arch>
#
# CI:
#   make test                    # go test ./helper/...
#   make check                   # go vet + test

BINARY  := ac-helper
PKG     := ./helper/...
GO      := go
DIST    := dist
PREFIX  ?= $(HOME)
BINDIR  := $(PREFIX)/bin

LDFLAGS := -s -w

.PHONY: all build install test vet check build-all clean help

all: build

help:
	@echo "Targets:"
	@echo "  build       - build $(BINARY) for host OS/arch ($(DIST)/$(BINARY))"
	@echo "  install     - build and copy to $(BINDIR)/$(BINARY)"
	@echo "  test        - go test ./helper/..."
	@echo "  vet         - go vet ./helper/..."
	@echo "  check       - vet + test"
	@echo "  build-all   - cross-compile for darwin/linux × arm64/amd64 into $(DIST)/"
	@echo "  clean       - remove $(DIST)/"

build: | $(DIST)
	cd helper && $(GO) build -ldflags '$(LDFLAGS)' -o ../$(DIST)/$(BINARY) .

install: build
	@mkdir -p $(BINDIR)
	install -m 0755 $(DIST)/$(BINARY) $(BINDIR)/$(BINARY)
	@echo "Installed $(BINDIR)/$(BINARY)"

test:
	cd helper && $(GO) test ./...

vet:
	cd helper && $(GO) vet ./...

check: vet test

build-all: | $(DIST)
	@for target in darwin/amd64 darwin/arm64 linux/amd64 linux/arm64; do \
	  os=$${target%/*}; arch=$${target#*/}; \
	  out="$(DIST)/$(BINARY)-$$os-$$arch"; \
	  echo "→ $$out"; \
	  (cd helper && GOOS=$$os GOARCH=$$arch CGO_ENABLED=0 $(GO) build -ldflags '$(LDFLAGS)' -o ../$$out .) || exit 1; \
	done

$(DIST):
	@mkdir -p $(DIST)

clean:
	rm -rf $(DIST)
