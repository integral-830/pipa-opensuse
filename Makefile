.PHONY: validate build help
help:
	@echo "make validate  - check repo structure/package lists are complete"
	@echo "make build     - run the full local build (needs root + real network)"
validate:
	./scripts/validate-recipe.sh
build:
	sudo ./scripts/ci-build-image.sh
