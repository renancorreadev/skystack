ASSETS    := assets
BIN       := .build/release/SkyVM
SOCK      := $(HOME)/.skystack/skyvm-docker.sock
CPUS      ?= 4
MEM       ?= 4

.PHONY: build-image package-image build sign validate run-vm clean-image agent-test

build-image: ## Build kernel + initramfs + rootfs into ./assets
	bash image-builder/build.sh

package-image: ## Package ./assets into a distributable bundle in ./dist (no Docker)
	bash image-builder/package.sh

agent-test: ## Test the guest agent proxy logic
	cd agent && go test ./...

build: ## Release build of SkyVM
	swift build -c release

sign: build ## Ad-hoc sign with the virtualization entitlement (required to boot)
	codesign --entitlements SkyVM.entitlements --sign - --force --timestamp=none $(BIN)
	@codesign -d --entitlements - $(BIN) 2>/dev/null | grep -q virtualization && echo "✓ signed with virtualization entitlement"

validate: build ## Build + validate the VM configuration against ./assets (no boot)
	$(BIN) --kernel $(ASSETS)/vmlinux --initrd $(ASSETS)/initramfs.gz \
	       --rootfs $(ASSETS)/rootfs.ext4 --validate-only

run-vm: sign ## Boot the guest and expose its Docker socket on the Mac
	@echo "booting SkyVM — guest Docker will appear at $(SOCK)"
	$(BIN) --kernel $(ASSETS)/vmlinux --initrd $(ASSETS)/initramfs.gz \
	       --rootfs $(ASSETS)/rootfs.ext4 \
	       --cpus $(CPUS) --memory-gib $(MEM) \
	       --docker-socket $(SOCK)

clean-image:
	rm -rf $(ASSETS)
