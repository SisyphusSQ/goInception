# syntax=docker/dockerfile:1

FROM --platform=$BUILDPLATFORM golang:1.22.12-alpine3.21 AS builder

ARG TARGETOS=linux
ARG TARGETARCH=amd64
ARG GHOST_VERSION=v1.1.11
ARG PT_VERSION=3.7.2
ARG APP_VERSION=unknown
ARG GIT_HASH=unknown
ARG GIT_BRANCH=unknown

RUN apk add --no-cache ca-certificates curl tar

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN mkdir -p /out \
  && BUILD_TS="$(date '+%Y-%m-%d %H:%M:%S')" \
  && GO_VER="$(go version)" \
  && CGO_ENABLED=0 GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" go build \
    -ldflags "-s -w \
      -X 'github.com/hanchuanchuan/goInception/mysql.TiDBReleaseVersion=${APP_VERSION}' \
      -X 'github.com/hanchuanchuan/goInception/util/printer.TiDBBuildTS=${BUILD_TS}' \
      -X 'github.com/hanchuanchuan/goInception/util/printer.TiDBGitHash=${GIT_HASH}' \
      -X 'github.com/hanchuanchuan/goInception/util/printer.TiDBGitBranch=${GIT_BRANCH}' \
      -X 'github.com/hanchuanchuan/goInception/util/printer.GoVersion=${GO_VER}'" \
    -o /out/goInception tidb-server/main.go

RUN set -eux; \
  GHOST_ARCHIVE="gh-ost-linux-${TARGETARCH}.tar.gz"; \
  curl -fsSL -o "/tmp/${GHOST_ARCHIVE}" "https://github.com/github/gh-ost/releases/download/${GHOST_VERSION}/${GHOST_ARCHIVE}"; \
  curl -fsSL -o /tmp/SHA256SUMS "https://github.com/github/gh-ost/releases/download/${GHOST_VERSION}/SHA256SUMS"; \
  (cd /tmp && grep "  ${GHOST_ARCHIVE}\$" SHA256SUMS | sha256sum -c -); \
  tar -xzf "/tmp/${GHOST_ARCHIVE}" -C /out gh-ost; \
  chmod +x /out/gh-ost; \
  rm -f "/tmp/${GHOST_ARCHIVE}" /tmp/SHA256SUMS

RUN set -eux; \
  curl -fsSL -o /out/pt-online-schema-change "https://raw.githubusercontent.com/percona/percona-toolkit/v${PT_VERSION}/bin/pt-online-schema-change"; \
  chmod +x /out/pt-online-schema-change

FROM alpine:3.24

ENV LANG="en_US.UTF-8" \
    TZ="Asia/Shanghai"

RUN apk add --no-cache \
    ca-certificates \
    dumb-init \
    perl \
    perl-dbi \
    perl-dbd-mysql \
    perl-io-socket-ssl \
    perl-term-readkey \
    tzdata \
  && ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime \
  && echo "${TZ}" > /etc/timezone

COPY --from=builder /out/goInception /goInception
COPY --from=builder /out/gh-ost /usr/local/bin/gh-ost
COPY --from=builder /out/pt-online-schema-change /usr/local/bin/pt-online-schema-change
COPY config/config.toml.default /etc/config.toml

WORKDIR /

EXPOSE 4000

ENTRYPOINT ["/usr/bin/dumb-init", "--", "/goInception", "--config=/etc/config.toml"]
