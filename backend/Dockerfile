FROM node:24.22.0-bookworm-slim

WORKDIR /app
ENV NODE_ENV=production \
    SAFEATHOME_HOST=0.0.0.0 \
    SAFEATHOME_DATABASE_CA_FILE=/app/certs/supabase-root-2021.crt

ENV MALLOC_ARENA_MAX=2 \
    VIPS_CONCURRENCY=1

COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force

COPY --chown=node:node src ./src
COPY --chown=node:node migrations ./migrations
COPY --chown=node:node certs/supabase-root-2021.crt ./certs/supabase-root-2021.crt
COPY --chown=node:node assets/forms/scfhp-41567.pdf ./assets/forms/scfhp-41567.pdf
COPY --chown=node:node assets/forms/hpsm-eaa-inert.pdf ./assets/forms/hpsm-eaa-inert.pdf
COPY --chown=node:node assets/forms/rtp-preparation-worksheet.pdf ./assets/forms/rtp-preparation-worksheet.pdf
COPY --chown=node:node assets/fonts/SafeAtHomeCJK-Regular.otf ./assets/fonts/SafeAtHomeCJK-Regular.otf
COPY --chown=node:node assets/fonts/SafeAtHomeCJK-Regular.metrics.bin ./assets/fonts/SafeAtHomeCJK-Regular.metrics.bin
COPY --chown=node:node assets/fonts/OFL.txt ./assets/fonts/OFL.txt
USER node

EXPOSE 8788
CMD ["node", "--max-old-space-size=64", "--max-semi-space-size=1", "src/api/durable-server.ts"]
