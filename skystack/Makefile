BINARY := skystack
PKG := github.com/skynance/skystack
VERSION ?= 0.1.0
LDFLAGS := -X $(PKG)/internal/cli.version=$(VERSION)

.PHONY: build install test vet fmt clean run

build: ## Build the skystack binary into ./bin
	go build -ldflags "$(LDFLAGS)" -o bin/$(BINARY) ./cmd/skystack

install: ## Install skystack into $GOBIN / $GOPATH/bin
	go install -ldflags "$(LDFLAGS)" ./cmd/skystack

test: ## Run the test suite
	go test ./...

vet: ## Run go vet
	go vet ./...

fmt: ## Format all Go sources
	gofmt -s -w .

clean:
	rm -rf bin

run: build ## Build then run (pass ARGS="ps -A")
	./bin/$(BINARY) $(ARGS)
