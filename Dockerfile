# syntax=docker/dockerfile:experimental


#   Copyright 2020 Docker Compose CLI authors

#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at

#       http://www.apache.org/licenses/LICENSE-2.0

#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

ARG GO_VERSION=1.16beta1-alpine
ARG GOLANGCI_LINT_VERSION=v1.33.0-alpine
ARG PROTOC_GEN_GO_VERSION=v1.4.3

FROM --platform=${BUILDPLATFORM} golang:${GO_VERSION} AS base
WORKDIR /compose-cli
ENV GO111MODULE=on
RUN apk add --no-cache \
    clang \
    git \
    docker \
    lld \
    llvm \
    make \
    protoc \
    protobuf-dev
COPY go.* .
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

FROM base AS make-protos
ARG PROTOC_GEN_GO_VERSION
RUN go get github.com/golang/protobuf/protoc-gen-go@${PROTOC_GEN_GO_VERSION}
COPY . .
RUN make -f builder.Makefile protos

FROM golangci/golangci-lint:${GOLANGCI_LINT_VERSION} AS lint-base

FROM base AS lint
ENV CGO_ENABLED=0
COPY --from=lint-base /usr/bin/golangci-lint /usr/bin/golangci-lint
ARG BUILD_TAGS
ARG GIT_TAG
RUN --mount=target=. \
    --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/root/.cache/golangci-lint \
    BUILD_TAGS=${BUILD_TAGS} \
    GIT_TAG=${GIT_TAG} \
    make -f builder.Makefile lint

FROM base AS import-restrictions-base
RUN go get github.com/docker/import-restrictions

FROM import-restrictions-base AS import-restrictions
RUN --mount=target=. \
    --mount=type=cache,target=/go/pkg/mod \
    make -f builder.Makefile import-restrictions

RUN MACOSX_DEPLOYMENT_TARGET=10.12 \
    GOOS=darwin GOARCH=amd64 CC=clang \
    CGO_CFLAGS="-isysroot$PWD/toolchain/MacOSX.sdk -target x86_64-apple-darwin -I./toolchain/MacOSX.sdk/usr/include/" \
    CGO_LDFLAGS="--sysroot ./toolchain/MacOSX.sdk -target x86_64-apple-darwin -F./toolchain/MacOSX.sdk/System/Library/Frameworks" \
    go build -x -trimpath -ldflags="-extld ld --linkmode external -s -w -X github.com/docker/compose-cli/internal.Version=" -o bin/docker ./cli

FROM base AS make-cli
ENV CGO_ENABLED=1
ARG TARGETOS
ARG TARGETARCH
ARG BUILD_TAGS
ARG GIT_TAG
COPY . .
RUN mv ld.sh /usr/bin/ld && chmod +x /usr/bin/ld
# RUN --mount=target=. \
#     --mount=type=cache,target=/go/pkg/mod \
#     --mount=type=cache,target=/root/.cache/go-build \
#     CC=clang CXX=clang++ CGO_CLFAGS="-itoolchain/MacOSX.sdk/usr/include" \
#     GOOS=${TARGETOS} \
#     GOARCH=${TARGETARCH} \
#     BUILD_TAGS=${BUILD_TAGS} \
#     GIT_TAG=${GIT_TAG} \
#     make BINARY=/out/docker -f builder.Makefile cli

FROM base AS make-cross
ARG BUILD_TAGS
ARG GIT_TAG
RUN --mount=target=. \
    --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    BUILD_TAGS=${BUILD_TAGS} \
    GIT_TAG=${GIT_TAG} \
    make BINARY=/out/docker  -f builder.Makefile cross

FROM scratch AS protos
COPY --from=make-protos /compose-cli/protos .

FROM scratch AS cli
COPY --from=make-cli /out/* .

FROM scratch AS cross
COPY --from=make-cross /out/* .

FROM base AS test
ENV CGO_ENABLED=0
ARG BUILD_TAGS
ARG GIT_TAG
RUN --mount=target=. \
    --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    BUILD_TAGS=${BUILD_TAGS} \
    GIT_TAG=${GIT_TAG} \
    make -f builder.Makefile test

FROM base AS check-license-headers
RUN go get -u github.com/kunalkushwaha/ltag
RUN --mount=target=. \
    make -f builder.Makefile check-license-headers

FROM base AS make-go-mod-tidy
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod tidy

FROM scratch AS go-mod-tidy
COPY --from=make-go-mod-tidy /compose-cli/go.mod .
COPY --from=make-go-mod-tidy /compose-cli/go.sum .

FROM base AS check-go-mod
COPY . .
RUN make -f builder.Makefile check-go-mod
