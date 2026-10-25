FROM node:24-alpine AS base
WORKDIR /app


FROM base AS deps
COPY package.json package-lock.json ./
RUN npm ci --omit=dev


FROM base AS test
ENV NODE_ENV=test
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
CMD ["sh", "-c", "npm run lint && npm test"]


FROM base AS production
ENV NODE_ENV=production
ARG GIT_SHA=dev
ENV APP_VERSION=$GIT_SHA
LABEL org.opencontainers.image.source="https://github.com/bhaskarDhi/notes-devops" \
      org.opencontainers.image.revision=$GIT_SHA
COPY --from=deps /app/node_modules ./node_modules
COPY package.json knexfile.js ./
COPY src ./src
COPY migrations ./migrations
COPY seeds ./seeds
COPY public ./public
RUN chmod -R a+rX /app
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3000/health || exit 1
CMD ["node", "src/server.js"]
