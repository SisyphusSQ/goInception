PROJECT := goInception
GOPATH ?= $(shell go env GOPATH)

ifneq "$(GOPATH)" ""
path_to_add := $(addsuffix /bin,$(subst :,/bin:,$(GOPATH)))
export PATH := $(path_to_add):$(PATH)
endif

FAIL_ON_STDOUT := awk '{ print } END { if (NR > 0) { exit 1 } }'

CURDIR := $(shell pwd)
UNAME_S := $(shell uname -s)

GOTOOLCHAIN ?= go1.22.12
GO        := GOTOOLCHAIN=$(GOTOOLCHAIN) GO111MODULE=on go
GOBUILD   := CGO_ENABLED=0 $(GO) build $(BUILD_FLAG)

VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
VERSION_EASY := $(shell git describe --tags --always 2>/dev/null || echo dev)
GIT_HASH := $(shell git rev-parse HEAD 2>/dev/null || echo unknown)
GIT_BRANCH := $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
BUILD_TS := $(shell date '+%Y-%m-%d %H:%M:%S')
GO_VERSION := $(shell $(GO) version)

# 指定部分单元测试跳过
ifeq ("$(SHORT)", "1")
	GOTEST := CGO_ENABLED=1 $(GO) test -p 3 -short
else
	GOTEST := CGO_ENABLED=1 $(GO) test -p 3
endif

PACKAGE_LIST := $(GO) list ./... | grep -vE "vendor"
PACKAGES := $$($(PACKAGE_LIST))
FILES := $$(find . -name "*.go" -not -path "./vendor/*" -not -path "./.git/*" -not -path "./tools/*")

GOFAIL_ENABLE  := $$(find $$PWD/ -type d | grep -vE "(\.git|vendor)" | xargs gofail enable)
GOFAIL_DISABLE := $$(find $$PWD/ -type d | grep -vE "(\.git|vendor)" | xargs gofail disable)

LDFLAGS += -X "github.com/hanchuanchuan/goInception/mysql.TiDBReleaseVersion=$(VERSION)"
LDFLAGS += -X "github.com/hanchuanchuan/goInception/util/printer.TiDBBuildTS=$(BUILD_TS)"
LDFLAGS += -X "github.com/hanchuanchuan/goInception/util/printer.TiDBGitHash=$(GIT_HASH)"
LDFLAGS += -X "github.com/hanchuanchuan/goInception/util/printer.TiDBGitBranch=$(GIT_BRANCH)"
LDFLAGS += -X "github.com/hanchuanchuan/goInception/util/printer.GoVersion=$(GO_VERSION)"

TEST_LDFLAGS := -X "github.com/hanchuanchuan/goInception/config.checkBeforeDropLDFlag=1"
CHECK_LDFLAGS += $(LDFLAGS) $(TEST_LDFLAGS)

TARGET ?=
IMAGE_NAME ?= hanchuanchuan/goinception
IMAGE_TAG ?= $(VERSION_EASY)

.PHONY: default all build buildsucc server server-admin-check server_check \
	goyacc parser parserlib fmt fmt-parser vet lint check \
	clean todo test gotest explaintest testapi race leak tikv_integration_test \
	benchkv benchraw benchdb importer checklist \
	gofail-enable gofail-disable release release2 docker docker-push docs level

default: server buildsucc

server-admin-check: server_check buildsucc

buildsucc:
	@echo "Build goInception Server successfully!"

all: dev server benchkv

dev: checklist test

build:
	$(GOBUILD) ./...

goyacc: bin/goyacc

bin/goyacc: parser/goyacc/main.go parser/goyacc/format_yacc.go
	@mkdir -p bin
	$(GO) build -o bin/goyacc parser/goyacc/main.go parser/goyacc/format_yacc.go

parser: parser/parser.go parser/hintparser.go

parser/parser.go: parser/parser.y bin/goyacc
	@echo "bin/goyacc -o $@ -p yy -t Parser $<"
	@bin/goyacc -o $@ -p yy -t Parser $< && echo 'SUCCESS!' || ( rm -f $@ && echo 'Please check y.output for more information' && exit 1 )
	@rm -f y.output
	# Clean invalid UTF-8 encoding at the end
	@echo "os: $(UNAME_S)"
ifeq ($(UNAME_S),Darwin)
	sed -i '' '$$d' $@
else
	sed -i '$$d' $@
endif
	gofmt -s -w $@

parser/hintparser.go: parser/hintparser.y bin/goyacc
	@echo "bin/goyacc -o $@ -p yyhint -t hintParser $<"
	@bin/goyacc -o $@ -p yyhint -t hintParser $< && echo 'SUCCESS!' || ( rm -f $@ && echo 'Please check y.output for more information' && exit 1 )
	@rm -f y.output
	# Clean invalid UTF-8 encoding at the end
	@echo "os: $(UNAME_S)"
ifeq ($(UNAME_S),Darwin)
	sed -i '' '$$d' $@
else
	sed -i '$$d' $@
endif
	gofmt -s -w $@

%arser_golden.y: parser/%arser.y bin/goyacc
	@bin/goyacc -fmt -fmtout $@ $<
	@(git diff --no-index --exit-code $< $@ && rm $@) || (mv $@ $< && >&2 echo "formatted $<" && exit 1)

parserlib: parser/parser.go

check: fmt vet

fmt:
	@echo "gofmt (simplify)"
	@gofmt -s -l -w $(FILES) 2>&1 | $(FAIL_ON_STDOUT)

fmt-parser: bin/goyacc parser_golden.y
	@echo "gofmt (simplify)"
	@gofmt -s -l -w . 2>&1 | $(FAIL_ON_STDOUT)

lint: tools/bin/revive
	@echo "linting"
	@tools/bin/revive -formatter friendly -config tools/check/revive.toml ./...

vet:
	@echo "vet"
	$(GO) vet ./...

clean:
	$(GO) clean -i ./...
	rm -rf *.out bin/goInception bin/goyacc bin/benchkv bin/benchraw bin/benchdb bin/importer release

todo:
	@grep -n '^[[:space:]]*_[[:space:]]*=[[:space:]][[:alpha:]][[:alnum:]]*' */*.go parser/parser.y || true
	@grep -n TODO */*.go parser/parser.y || true
	@grep -n BUG */*.go parser/parser.y || true
	@grep -n println */*.go parser/parser.y || true

test: checklist gotest explaintest

explaintest: server
	@cd cmd/explaintest && ./run-tests.sh -s ../../bin/goInception

gotest:
	$(GO) install github.com/etcd-io/gofail@v0.0.0-20180808172546-51ce9a71510a
	@$(GOFAIL_ENABLE)
ifeq ("$(API)", "1")
	@echo "Running in native mode (API)."
	@export log_level=error; \
	$(GOTEST) -timeout 30m -ldflags '$(TEST_LDFLAGS)' github.com/hanchuanchuan/goInception/session -api || { $(GOFAIL_DISABLE); exit 1; }
else
	@echo "Running in native mode."
	@export log_level=error; \
	$(GOTEST) -timeout 30m -ldflags '$(TEST_LDFLAGS)' -cover $(PACKAGES) || { $(GOFAIL_DISABLE); exit 1; }
endif
	@$(GOFAIL_DISABLE)

testapi:
	@echo "Running in native mode (API)."
	@export log_level=error; \
	$(GOTEST) -timeout 30m -ldflags '$(TEST_LDFLAGS)' github.com/hanchuanchuan/goInception/session -api

race:
	$(GO) install github.com/etcd-io/gofail@v0.0.0-20180808172546-51ce9a71510a
	@$(GOFAIL_ENABLE)
	@export log_level=debug; \
	$(GOTEST) -timeout 30m -race $(PACKAGES) || { $(GOFAIL_DISABLE); exit 1; }
	@$(GOFAIL_DISABLE)

leak:
	$(GO) install github.com/etcd-io/gofail@v0.0.0-20180808172546-51ce9a71510a
	@$(GOFAIL_ENABLE)
	@export log_level=debug; \
	$(GOTEST) -tags leak $(PACKAGES) || { $(GOFAIL_DISABLE); exit 1; }
	@$(GOFAIL_DISABLE)

tikv_integration_test:
	$(GO) install github.com/etcd-io/gofail@v0.0.0-20180808172546-51ce9a71510a
	@$(GOFAIL_ENABLE)
	$(GOTEST) ./store/tikv/. -with-tikv=true || { $(GOFAIL_DISABLE); exit 1; }
	@$(GOFAIL_DISABLE)

RACE_FLAG =
ifeq ("$(WITH_RACE)", "1")
	RACE_FLAG = -race
	GOBUILD   = CGO_ENABLED=1 $(GO) build $(BUILD_FLAG)
endif

CHECK_FLAG =
ifeq ("$(WITH_CHECK)", "1")
	CHECK_FLAG = $(TEST_LDFLAGS)
endif

server:
ifeq ($(strip $(TARGET)),)
	@mkdir -p bin
	$(GOBUILD) $(RACE_FLAG) -ldflags '$(LDFLAGS) $(CHECK_FLAG)' -o bin/goInception tidb-server/main.go
else
	@mkdir -p "$(dir $(TARGET))"
	$(GOBUILD) $(RACE_FLAG) -ldflags '$(LDFLAGS) $(CHECK_FLAG)' -o '$(TARGET)' tidb-server/main.go
endif

server_check:
ifeq ($(strip $(TARGET)),)
	@mkdir -p bin
	$(GOBUILD) $(RACE_FLAG) -ldflags '$(CHECK_LDFLAGS)' -o bin/goInception tidb-server/main.go
else
	@mkdir -p "$(dir $(TARGET))"
	$(GOBUILD) $(RACE_FLAG) -ldflags '$(CHECK_LDFLAGS)' -o '$(TARGET)' tidb-server/main.go
endif

benchkv:
	@mkdir -p bin
	$(GOBUILD) -ldflags '$(LDFLAGS)' -o bin/benchkv cmd/benchkv/main.go

benchraw:
	@mkdir -p bin
	$(GOBUILD) -ldflags '$(LDFLAGS)' -o bin/benchraw cmd/benchraw/main.go

benchdb:
	@mkdir -p bin
	$(GOBUILD) -ldflags '$(LDFLAGS)' -o bin/benchdb cmd/benchdb/main.go

importer:
	@mkdir -p bin
	$(GOBUILD) -ldflags '$(LDFLAGS)' -o bin/importer ./cmd/importer

checklist:
	cat checklist.md

gofail-enable:
	@$(GOFAIL_ENABLE)

gofail-disable:
	@$(GOFAIL_DISABLE)

tools/bin/revive: tools/check/go.mod
	cd tools/check && $(GO) build -o ../bin/revive github.com/mgechev/revive

# windows无法build,github.com/outbrain/golib有引用syslog.Writer,其在windows未实现.
release:
	@echo "Cross platform building for release ($(VERSION)) ..."
	@mkdir -p release
	@GOOS=darwin GOARCH=amd64 $(GOBUILD) -ldflags '-s -w $(LDFLAGS)' -o release/goInception tidb-server/main.go
	@tar -czf release/goInception-macOS-amd64-$(VERSION).tar.gz -C release goInception -C .. config/config.toml.default
	@rm -f release/goInception

	@GOOS=linux GOARCH=amd64 $(GOBUILD) -ldflags '-s -w $(LDFLAGS)' -o release/goInception tidb-server/main.go
	@tar -czf release/goInception-linux-amd64-$(VERSION).tar.gz -C release goInception -C .. config/config.toml.default
	@rm -f release/goInception

	@GOOS=darwin GOARCH=arm64 $(GOBUILD) -ldflags '-s -w $(LDFLAGS)' -o release/goInception tidb-server/main.go
	@tar -czf release/goInception-macOS-arm64-$(VERSION).tar.gz -C release goInception -C .. config/config.toml.default
	@rm -f release/goInception

	@GOOS=linux GOARCH=arm64 $(GOBUILD) -ldflags '-s -w $(LDFLAGS)' -o release/goInception tidb-server/main.go
	@tar -czf release/goInception-linux-arm64-$(VERSION).tar.gz -C release goInception -C .. config/config.toml.default
	@rm -f release/goInception

release2:
	@echo "Cross platform building for release ($(VERSION_EASY)) ..."
	@mkdir -p release
	@GOOS=darwin GOARCH=amd64 $(GOBUILD) -ldflags '-s -w $(LDFLAGS)' -o release/goInception tidb-server/main.go
	@tar -czf release/goInception-macOS-amd64-$(VERSION_EASY).tar.gz -C release goInception -C .. config/config.toml.default
	@rm -f release/goInception

	@GOOS=linux GOARCH=amd64 $(GOBUILD) -ldflags '-s -w $(LDFLAGS)' -o release/goInception tidb-server/main.go
	@tar -czf release/goInception-linux-amd64-$(VERSION_EASY).tar.gz -C release goInception -C .. config/config.toml.default
	@rm -f release/goInception

	@GOOS=darwin GOARCH=arm64 $(GOBUILD) -ldflags '-s -w $(LDFLAGS)' -o release/goInception tidb-server/main.go
	@tar -czf release/goInception-macOS-arm64-$(VERSION_EASY).tar.gz -C release goInception -C .. config/config.toml.default
	@rm -f release/goInception

	@GOOS=linux GOARCH=arm64 $(GOBUILD) -ldflags '-s -w $(LDFLAGS)' -o release/goInception tidb-server/main.go
	@tar -czf release/goInception-linux-arm64-$(VERSION_EASY).tar.gz -C release goInception -C .. config/config.toml.default
	@rm -f release/goInception

docker:
	docker build \
		--build-arg APP_VERSION="$(VERSION)" \
		--build-arg GIT_HASH="$(GIT_HASH)" \
		--build-arg GIT_BRANCH="$(GIT_BRANCH)" \
		-t $(IMAGE_NAME):$(IMAGE_TAG) \
		-t $(IMAGE_NAME):latest .

docker-push:
	docker push $(IMAGE_NAME):$(IMAGE_TAG)
	docker push $(IMAGE_NAME):latest

docs:
	bash docs/deploy.sh

level:
	$(GO) run config/generate_levels/main.go
	gofmt -w config/error_level.go
