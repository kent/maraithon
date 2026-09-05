.PHONY: setup setup-companion-signing reset-companion-fda run-companion \
	generate generate-native generate-companion generate-mobile \
	build build-all build-web build-api build-static build-assets build-native build-companion build-mobile \
	test test-full test-web test-api test-native test-companion test-mobile \
	verify verify-full verify-web verify-api verify-static verify-assets verify-native verify-companion verify-mobile verify-production-mobile \
	archive-mobile upload-mobile testflight-mobile ship-mobile \
	deploy deploy-web deploy-companion deploy-hardened release-companion

setup:
	mix setup

setup-companion-signing:
	apps/companion/scripts/create_dev_signing_identity.sh

reset-companion-fda:
	scripts/monorepo/reset-companion-fda

run-companion: deploy-companion

generate:
	scripts/monorepo/generate

generate-native:
	scripts/monorepo/generate native

generate-companion:
	scripts/monorepo/generate companion

generate-mobile:
	scripts/monorepo/generate mobile

build:
	scripts/monorepo/build web

build-all:
	scripts/monorepo/build

build-web:
	scripts/monorepo/build web

build-api: build-web

build-static:
	scripts/monorepo/assets web

build-assets:
	scripts/monorepo/assets all

build-native:
	scripts/monorepo/build native

build-companion:
	scripts/monorepo/build companion

build-mobile:
	scripts/monorepo/build mobile

test:
	scripts/monorepo/build web
	@echo "Broad tests skipped. Use make test-full or a focused test command when needed."

test-full:
	scripts/monorepo/test

test-web:
	scripts/monorepo/test web

test-api: test-web

test-native:
	scripts/monorepo/test native

test-companion:
	scripts/monorepo/test companion

test-mobile:
	scripts/monorepo/test mobile

verify:
	scripts/monorepo/build web
	@echo "Minimal verification complete. Use make verify-full for the full suite."

verify-full:
	scripts/monorepo/verify

verify-web:
	scripts/monorepo/verify web

verify-api: verify-web

verify-static:
	scripts/monorepo/verify static

verify-assets:
	scripts/monorepo/verify assets

verify-native:
	scripts/monorepo/verify native

verify-companion:
	scripts/monorepo/verify companion

verify-mobile:
	scripts/monorepo/verify mobile

verify-production-mobile:
	scripts/monorepo/mobile-production-verify

archive-mobile:
	apps/mobile/scripts/archive.sh

upload-mobile:
	apps/mobile/scripts/upload.sh

testflight-mobile:
	apps/mobile/scripts/testflight.sh

ship-mobile: testflight-mobile

deploy:
	scripts/monorepo/deploy-fast

deploy-web: deploy

deploy-companion:
	scripts/monorepo/run companion

deploy-hardened:
	scripts/monorepo/deploy

release-companion:
	apps/companion/scripts/release.sh
