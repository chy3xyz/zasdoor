# zasdoor — production image (API service).
# The frontend is a static SPA: serve `web/dist` from any static host and
# proxy `/api` (and `/health`, `/metrics`) to this image on :8000.
#
# Build context must be the repository root. The Zig build depends on sibling
# checkouts of zigmodu/zent at <root>/zig_ws/* (see build.zig.zon).

# ── Stage 1: build the Zig backend ─────────────────────────────────────────
FROM ziglang/zig:0.17.0-dev.1567 AS backend-build
WORKDIR /build/w4_proj
RUN git clone --depth 1 https://github.com/chy3xyz/zigmodu.git zig_ws/zigmodu \
 && git clone --depth 1 https://github.com/chy3xyz/zent.git zig_ws/zent
COPY . dev_machine/_adm_frame_/zmadmin/
WORKDIR /build/w4_proj/dev_machine/_adm_frame_/zmadmin
RUN zig build -Doptimize=ReleaseSafe

# ── Stage 2: build the SolidJS frontend ────────────────────────────────────
FROM node:22-alpine AS web-build
WORKDIR /build
COPY web/ ./web/
RUN corepack enable \
 && cd web && pnpm install --frozen-lockfile && pnpm run build

# ── Stage 3: runtime ───────────────────────────────────────────────────────
FROM alpine:3.20
RUN apk add --no-cache libc6-compat ca-certificates
WORKDIR /app
COPY --from=backend-build /build/w4_proj/dev_machine/_adm_frame_/zmadmin/zig-out/bin/zasdoor /usr/local/bin/zasdoor
COPY --from=backend-build /build/w4_proj/dev_machine/_adm_frame_/zmadmin/zig-out/bin/zasdoor-admin /usr/local/bin/zasdoor-admin
# Optional: bake the SPA into the image (served by your static host / nginx).
COPY --from=web-build /build/web/dist /app/web-dist
ENV ZASDOOR_HTTP_PORT=8000 \
    ZASDOOR_DB_DRIVER=sqlite \
    ZASDOOR_SQLITE_PATH=/data/zasdoor.db \
    ZASDOOR_UPLOAD_DIR=/data/uploads
VOLUME ["/data"]
EXPOSE 8000
CMD ["zasdoor"]
