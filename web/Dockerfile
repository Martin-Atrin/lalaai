# Relay + built PWA in one small image — everything a self-hosted relay needs. Build context: web/
FROM node:22-alpine AS pwa
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN corepack enable
WORKDIR /app
COPY shared ./shared
COPY pwa/package.json pwa/pnpm-lock.yaml* ./pwa/
RUN cd pwa && pnpm install --frozen-lockfile || pnpm install
COPY pwa ./pwa
RUN cd pwa && pnpm build

FROM oven/bun:1-alpine
WORKDIR /app
COPY shared ./shared
COPY relay/src ./relay/src
COPY --from=pwa /app/pwa/dist ./pwa/dist
ENV PORT=8787 STATIC_DIR=/app/pwa/dist
EXPOSE 8787
CMD ["bun", "relay/src/server.ts"]
