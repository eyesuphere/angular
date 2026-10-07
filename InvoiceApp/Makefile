# Development entry points. `make help` lists them.
#
# The .xcodeproj is generated, not committed: see project.yml.

XCODEGEN := $(shell command -v xcodegen 2>/dev/null)
PROJECT  := Invoices.xcodeproj
SCHEME   := Invoices-All
DEST     := platform=macOS

.DEFAULT_GOAL := help

.PHONY: help
help: ## List the available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: bootstrap
bootstrap: ## Install the tools needed to generate the project
	@./scripts/bootstrap.sh

$(PROJECT): project.yml Package.swift $(wildcard Config/*.xcconfig)
	@$(MAKE) --no-print-directory project

.PHONY: project
project: ## Generate Invoices.xcodeproj from project.yml
ifndef XCODEGEN
	@echo "xcodegen not found. Run 'make bootstrap' first." >&2
	@exit 1
endif
	xcodegen generate --spec project.yml --project .
	@echo "Generated $(PROJECT). Open it with 'make open'."

.PHONY: open
open: $(PROJECT) ## Open the project in Xcode
	open $(PROJECT)

.PHONY: core-test
core-test: ## Run the InvoiceCore tests through SwiftPM (no Xcode needed)
	swift test

.PHONY: build
build: $(PROJECT) ## Build the app
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)'

.PHONY: test
test: $(PROJECT) ## Run every test target through Xcode
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)'

.PHONY: ci
ci: ## Everything CI should run
	@./scripts/ci.sh

.PHONY: clean
clean: ## Remove build output and the generated project
	rm -rf .build DerivedData $(PROJECT)
