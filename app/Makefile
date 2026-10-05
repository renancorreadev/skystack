.PHONY: run build app pkg clean

run: ## Run the app from the build tree (dev)
	swift run SkyStackApp

build: ## Release build of the SwiftUI binary
	swift build -c release

app: ## Package a self-contained, signed SkyStack.app into ./dist
	bash packaging/package-app.sh

pkg: app ## Build the persistent macOS installer (SkyStack-Installer.pkg) into ./dist
	bash packaging/build-pkg.sh

clean:
	rm -rf .build dist
