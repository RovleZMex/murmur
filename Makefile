.PHONY: build install release assets test clean

build:      ## Build build/Murmur.app
	@scripts/build.sh

install:    ## Build, install to ~/Applications and launch
	@scripts/build.sh --install

release:    ## Universal, Developer ID signed and notarized dmg in dist/
	@scripts/build.sh --release

test:       ## Run the test suite
	swift test

assets:     ## Regenerate the app icon and README banner
	@swift scripts/make-assets.swift

clean:
	rm -rf build dist .build
