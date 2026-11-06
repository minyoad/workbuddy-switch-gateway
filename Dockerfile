# syntax=docker/dockerfile:1
#
# WorkBuddy Switch Gateway —— 远程服务器 Docker 部署镜像
#
# 形态：无头 webui 服务（wb-switch-server，Rust + axum）
#   * 端口 57890：webui 管理界面（浏览器访问）
#   * 端口 7863 ：OpenAI 兼容网关（Go 子进程，端口可在 webui 内修改）
#   * 数据目录  ：/root/.wb-switch（必须挂卷持久化）
#   * 鉴权      ：环境变量 WB_SWITCH_API_KEY 设置后，webui 与 API 均需密钥
#
# 构建（全部阶段）：docker compose build
# 仅重建 Rust 服务端（前端/网关产物已缓存在阶段里）：docker build --target server .
#
# 所有依赖下载与编译产物均使用 BuildKit 缓存挂载，重复构建不会重编译依赖。
#
# 国内网络建议替换基础镜像源（阿里云/腾讯云等镜像仓库均可）：
#   docker compose build \
#     --build-arg NODE_IMAGE=registry.cn-hangzhou.aliyuncs.com/library/node:22-bookworm-slim \
#     --build-arg GO_IMAGE=registry.cn-hangzhou.aliyuncs.com/library/golang:1.24-bookworm \
#     --build-arg RUST_IMAGE=registry.cn-hangzhou.aliyuncs.com/library/rust:1-bookworm \
#     --build-arg RUNTIME_IMAGE=registry.cn-hangzhou.aliyuncs.com/library/debian:bookworm-slim

ARG NODE_IMAGE=node:22-bookworm-slim
ARG GO_IMAGE=golang:1.24-bookworm
ARG RUST_IMAGE=rust:1-bookworm
ARG RUNTIME_IMAGE=debian:bookworm-slim

# ---------------------------------------------------------------------------
# 1) 前端（React + Vite）→ dist/
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS web

WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci

COPY tsconfig.json tsconfig.node.json vite.config.ts index.html components.json ./
COPY public ./public
COPY src ./src
RUN npm run build

# ---------------------------------------------------------------------------
# 2) Go 网关（workbuddy2api 上游固定提交 + 国际版补丁）→ 静态 Linux 二进制
# ---------------------------------------------------------------------------
FROM ${GO_IMAGE} AS gateway

ARG GATEWAY_REPO=https://github.com/HanawaBanana/workbuddy2api.git
ARG GATEWAY_REF=cfb1713fb9f0692aa19aae7e7a6d6c2453235a38

WORKDIR /src
RUN git clone "${GATEWAY_REPO}" . \
    && git checkout "${GATEWAY_REF}"

# 与桌面版构建流程一致：在网关仓库根应用本仓库维护的补丁
COPY patches/intl-support.patch /tmp/intl-support.patch
RUN git apply --check /tmp/intl-support.patch \
    && git apply /tmp/intl-support.patch

RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/gateway ./cmd/server

# ---------------------------------------------------------------------------
# 3) 服务端（Rust）：内嵌前端 dist 与网关二进制，产出单文件 wb-switch
# ---------------------------------------------------------------------------
FROM ${RUST_IMAGE} AS server

WORKDIR /app
# 先拷 manifest 以利用层缓存（依赖不变时不重复解析）
COPY Cargo.toml Cargo.lock ./
COPY crates ./crates
# 容器构建只含 server/core：从 workspace 成员里剔除桌面端 src-tauri，
# 否则 cargo 会因 src-tauri/src/lib.rs 缺失而拒绝解析整个 workspace
RUN sed -i 's/, "src-tauri"//' Cargo.toml

COPY --from=web /app/dist ./dist
COPY --from=gateway /out/gateway /build/gateway
# build.rs 据此把网关 gzip 内嵌进 wb-switch 主程序
ENV WB_SWITCH_GATEWAY_BIN=/build/gateway

# target 目录走缓存挂载 → 必须在同一 RUN 内把产物拷出（缓存层不进镜像）
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/app/target \
    cargo build --release -p wb-switch-server \
 && cp target/release/wb-switch /build/wb-switch

# ---------------------------------------------------------------------------
# 4) 运行时
# ---------------------------------------------------------------------------
FROM ${RUNTIME_IMAGE}

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=server /build/wb-switch /usr/local/bin/wb-switch

# 数据目录（账号库、网关凭证、state.json、签到日志）必须挂卷
VOLUME ["/root/.wb-switch"]

# webui 默认 57890；网关默认 7863（若在 webui 内改端口，运行参数需同步调整）
EXPOSE 57890 7863

# 远程监听（非 127.0.0.1）时服务端会自动跳过开浏览器；--no-open 双保险
ENTRYPOINT ["wb-switch", "--host", "0.0.0.0", "--no-open"]
