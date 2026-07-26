# syntax=docker/dockerfile:1.7
FROM node:24-alpine AS builder
WORKDIR /app
COPY adapters/protocol-ts/package.json adapters/protocol-ts/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY adapters/protocol-ts/tsconfig.json ./
COPY adapters/protocol-ts/src ./src
RUN npm run build && npm prune --omit=dev

FROM node:24-alpine AS runtime
ENV NODE_ENV=production
WORKDIR /app
COPY --from=builder --chown=node:node /app/package.json /app/package-lock.json ./
COPY --from=builder --chown=node:node /app/node_modules ./node_modules
COPY --from=builder --chown=node:node /app/dist ./dist
USER node
EXPOSE 8090
HEALTHCHECK --interval=5s --timeout=2s --retries=12 \
  CMD wget -q -O /dev/null http://127.0.0.1:8090/ || exit 1
ENTRYPOINT ["node", "dist/index.js"]
