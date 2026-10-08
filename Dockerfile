# syntax=docker/dockerfile:1.7
#
# ProxyPin web: the Flutter web UI + a headless reverse-proxy server on ONE port.
#   docker build -t proxypin-web .
#   docker run -p 8080:8080 -v proxypin-data:/data proxypin-web
#   UI:    http://localhost:8080/__proxypin/
#   Proxy: http://localhost:8080/<rule path>   (rules are managed in the UI)

ARG FLUTTER_VERSION=3.44.9
ARG NODE_VERSION=22

# ---------------------------------------------------------------- Flutter SDK (pinned, same as .fvmrc)
FROM debian:bookworm-slim AS sdk
ARG FLUTTER_VERSION
RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl ca-certificates unzip xz-utils zip \
 && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch ${FLUTTER_VERSION} https://github.com/flutter/flutter.git /opt/flutter
ENV PATH=/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:$PATH \
    FLUTTER_SUPPRESS_ANALYTICS=true \
    PUB_CACHE=/opt/pub-cache
RUN flutter config --no-analytics --no-cli-animations --enable-web \
 && flutter precache --web --no-android --no-ios --no-linux --no-windows --no-macos --no-fuchsia \
 && dart --disable-analytics \
 && flutter --version

# ---------------------------------------------------------------- dependencies (cached until pubspec changes)
FROM sdk AS deps
WORKDIR /src
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get --enforce-lockfile

# ---------------------------------------------------------------- headless server (plain Dart, AOT)
FROM deps AS server
COPY . .
# `dart build cli` (not `dart compile exe`): the package graph contains build hooks (objective_c, a no-op on Linux)
RUN flutter pub get --enforce-lockfile --offline \
 && dart build cli -t bin/proxypin_server.dart -o /out

# ---------------------------------------------------------------- web UI (served below /__proxypin/)
FROM deps AS web
COPY . .
RUN flutter pub get --enforce-lockfile --offline \
 && flutter build web --release --base-href /__proxypin/ --no-web-resources-cdn --no-wasm-dry-run

# ---------------------------------------------------------------- runtime: Node runs user scripts
FROM node:${NODE_VERSION}-bookworm-slim AS runtime
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libzstd1 tini \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /data /app \
 && chown node:node /data
WORKDIR /app
COPY --from=server /out/bundle /app/bundle
COPY --from=web /src/build/web /app/web
COPY assets/certs /app/assets/certs
COPY assets/js /app/assets/js
COPY server/js /app/server/js

ENV PORT=8080 \
    PROXYPIN_HOME=/app \
    PROXYPIN_DATA_DIR=/data \
    PROXYPIN_WEB_DIR=/app/web \
    PROXYPIN_NODE=/usr/local/bin/node \
    PROXYPIN_SCRIPT_WORKER=/app/server/js/script_worker.mjs

USER node
VOLUME ["/data"]
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8080)+'/__proxypin/api/session').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
ENTRYPOINT ["/usr/bin/tini", "--", "/app/bundle/bin/proxypin_server"]
