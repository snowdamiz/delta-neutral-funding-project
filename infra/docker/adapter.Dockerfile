# syntax=docker/dockerfile:1.7
ARG CODE_COMMIT=development
FROM node:24-alpine AS builder
WORKDIR /app
COPY adapters/protocol-ts/package.json adapters/protocol-ts/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY adapters/protocol-ts/tsconfig.json ./
COPY adapters/protocol-ts/src ./src
COPY tests/vectors /tests/vectors
RUN CONFORMANCE_VECTOR_DIR=/tests/vectors npm test

FROM gcr.io/distroless/nodejs24-debian13:nonroot@sha256:af85d11ce7ef10172855a6e3649e3e8125b1b9e3ca41849ec2918036f05cb212 AS runtime
ARG CODE_COMMIT
ENV NODE_ENV=production
LABEL org.opencontainers.image.revision=$CODE_COMMIT
WORKDIR /app
COPY --from=builder --chown=65532:65532 /app/dist ./dist
USER 65532:65532
EXPOSE 8090
HEALTHCHECK --interval=5s --timeout=2s --retries=12 \
  CMD ["/nodejs/bin/node", "-e", "fetch('http://127.0.0.1:8090/').then(response=>{if(!response.ok)process.exit(1)}).catch(()=>process.exit(1))"]
CMD ["dist/index.js"]
