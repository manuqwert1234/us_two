.PHONY: proto proto-install build clean run-manager run-worker docker-up docker-down lint vet test tidy certs

BINARY_DIR   := bin
PROTO_DIR    := proto
PROTO_OUT    := proto

# ─── Proto ─────────────────────────────────────────────────────────────────────
proto-install:
	@echo "→ Installing protoc-gen-go plugins..."
	go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
	go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
	@echo "✓ Plugins installed."

proto: proto-install
	@echo "→ Generating gRPC / Protobuf stubs..."
	PATH="$$PATH:$$(go env GOPATH)/bin" protoc \
		--go_out=. \
		--go_opt=paths=source_relative \
		--go-grpc_out=. \
		--go-grpc_opt=paths=source_relative \
		$(PROTO_DIR)/titan.proto
	@echo "✓ Protobuf generation complete."

# ─── Binary Builds ─────────────────────────────────────────────────────────────
build: build-manager build-worker build-cli

build-manager:
	@mkdir -p $(BINARY_DIR)
	@echo "→ Building manager..."
	go build -o $(BINARY_DIR)/manager ./cmd/manager
	@echo "✓ manager binary ready."

build-worker:
	@mkdir -p $(BINARY_DIR)
	@echo "→ Building worker..."
	go build -o $(BINARY_DIR)/worker ./cmd/worker
	@echo "✓ worker binary ready."

build-cli:
	@mkdir -p $(BINARY_DIR)
	@echo "→ Building CLI..."
	go build -o $(BINARY_DIR)/titan ./cmd/cli
	@echo "✓ titan CLI binary ready."

# ─── Local Dev Runs ────────────────────────────────────────────────────────────
run-manager:
	go run ./cmd/manager --port=50051

run-worker:
	go run ./cmd/worker --manager=localhost:50051 --id=$(WORKER_ID)

# ─── Docker ────────────────────────────────────────────────────────────────────
docker-up:
	docker-compose up --build

docker-down:
	docker-compose down --remove-orphans

# ─── Quality ───────────────────────────────────────────────────────────────────
vet:
	@echo "→ Running go vet..."
	go vet ./...
	@echo "✓ go vet passed."

lint: vet
	@echo "→ Running staticcheck / golangci-lint..."
	@which golangci-lint > /dev/null 2>&1 && golangci-lint run ./... || echo "⚠ golangci-lint not installed, skipping. Install: go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest"

test:
	@echo "→ Running tests..."
	go test -v -count=1 -race ./internal/...
	@echo "✓ All tests passed."

# ─── TLS Certs ─────────────────────────────────────────────────────────────────
certs:
	@echo "→ Generating self-signed TLS certificates..."
	@mkdir -p certs
	@./scripts/gen-certs.sh
	@echo "✓ Certs generated in certs/"

# ─── Utilities ─────────────────────────────────────────────────────────────────
tidy:
	go mod tidy

clean:
	rm -rf $(BINARY_DIR)
	rm -f $(PROTO_OUT)/titan.pb.go $(PROTO_OUT)/titan_grpc.pb.go

# ─── CI Pipeline ───────────────────────────────────────────────────────────────
ci: tidy vet test build
	@echo "✓ CI pipeline passed."
