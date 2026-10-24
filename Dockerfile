FROM node:24.21.0-bookworm-slim

ENV DSH_HOME=/data/.dsh \
    HOME=/data \
    DSH_VERSION=latest \
    NPM_CONFIG_UPDATE_NOTIFIER=false

LABEL org.opencontainers.image.source="https://github.com/yunjies/docker-for-dsh"

RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable \
    && corepack prepare pnpm@11.7.0 --activate

COPY bootstrap.sh /usr/local/bin/dsh-bootstrap
COPY dsh-web-runner.mjs /usr/local/bin/dsh-web-runner.mjs
COPY dsh-home.patch.yml /opt/dsh-home.patch.yml
RUN chmod 0755 /usr/local/bin/dsh-bootstrap \
    && chmod 0644 /usr/local/bin/dsh-web-runner.mjs /opt/dsh-home.patch.yml \
    && mkdir -p /workspace

WORKDIR /workspace
VOLUME ["/data", "/workspace"]
EXPOSE 3080
USER root
ENTRYPOINT ["/usr/local/bin/dsh-bootstrap"]
