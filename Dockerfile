# syntax=docker/dockerfile:1
###
# Build the whole package-repo tree at image build time, serve it as static files.
# Immutable: a Luggage release = manifest commit = new image = rollout. No PVC, no
# in-place publish jobs. The signing key arrives as a BuildKit secret — it exists
# only during the RUN, never in a layer, and the final stage copies public/ only.
###
FROM debian:bookworm-slim AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
        reprepro createrepo-c gnupg curl ca-certificates jq \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY . .
RUN --mount=type=secret,id=gpgkey \
    GPG_KEY_FILE=/run/secrets/gpgkey ./scripts/build-repos.sh

FROM dhi.io/nginx:1-alpine3.23
COPY deploy/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /build/public /usr/share/nginx/html
