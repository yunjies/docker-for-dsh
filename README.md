# docker-for-dsh

A reusable DSH Web container based on `node:24.21.0-bookworm-slim`. The DSH process runs as container-root, Git is baked into the image, and apt remains available for runtime package setup. The container is not privileged and must not receive the Docker socket.

## Build and publish

Build from this directory:

```sh
docker build -t docker-for-dsh:local .
```

GitHub Actions publishes `ghcr.io/yunjies/docker-for-dsh:latest` and the source commit SHA tag for pushes to `main` or a manual dispatch. The workflow uses the repository-provided `GITHUB_TOKEN` with only contents-read and packages-write permissions. Set the GHCR package visibility to public for unauthenticated Unraid pulls.

## Docker Compose

Copy `.env.example` to `.env`, then set `DSH_PUBLIC_URL`, `DSH_TRUSTED_HOST`, `DSH_DATA_HOST_PATH`, `DSH_WORKSPACE_HOST_PATH`, `DSH_PROXY_REGISTRATION_URL`, `DSH_PROXY_API_HOST`, `DSH_PROXY_API_IP`, `DSH_PROXY_REGISTRATION_SECRET_FILE`, and `DSH_PROXY_UPSTREAM_IP`. The Compose service sends each newly observed DSH launch token to the HTTPS registrar as JSON `{ "ip", "web_port", "token" }` with a Bearer credential read from the mounted secret file. `DSH_PROXY_API_HOST` is mapped to `DSH_PROXY_API_IP` in the container so TLS hostname verification remains enabled; the registrar independently checks the caller's source IP. The proxy service validates and records the registration, then updates the Nginx upstream and token map. The `DSH_WEB_HOST_PORT` published by Compose is the registered web port. See [`proxy-registry/README.md`](proxy-registry/README.md) for deploying the service on the reverse-proxy host. Keep `.env` and the bearer secret private; `.env` is ignored by Git and excluded from the image build context.

This removes the need for Docker to SSH into the proxy. The registrar credential is limited to registration, but DSH runs as container-root and can read the mounted secret; protect Docker access and do not reuse the credential for other services. The registrar is exposed through the existing HTTPS Nginx listener, requires both an authorized source IP and a valid Bearer credential, and does not log request bodies or tokens.

Validate the staged settings with `docker compose config`. To convert the existing manually created `dsh` container, keep its `/data` and `/workspace` bind paths in `.env`, then from the directory containing `docker-compose.yml`, stop and rename the old container before Compose takes the `dsh` name:

```sh
docker stop dsh
docker rename dsh dsh-pre-token-api
docker update --restart=no dsh-pre-token-api
docker compose up -d --build
```

Compose manages the container named `dsh`, joins the existing `dsh-private` network, and publishes only the Web port; inbound container SSH is not published by default. Set `DSH_WEB_BIND_IP` and `DSH_WEB_HOST_PORT` to the host bind address and port the reverse proxy is configured to reach. Keep the old container stopped but available until the new launch token is registered and the external route works. To roll back, run `docker compose down`, restore the old restart policy, rename it to `dsh`, and start it. Do not remove the old container or its bind-mounted data until verification is complete.

For Unraid, load the template from <https://raw.githubusercontent.com/yunjies/docker-for-dsh/main/unraid/dsh.xml> and select the existing `dsh-private` Docker network. The template defaults to container name `dsh-sec`, host web port `13081`, and appdata paths under `/mnt/user/appdata/dsh-sec`; choose a fixed private-network IP only when other consumers require it. For the HTTPS JSON registrar, set `DSH_PROXY_REGISTRATION_URL`, `DSH_PROXY_UPSTREAM_IP`, and `DSH_WEB_HOST_PORT` (the latter must match the Web UI host port mapping), then mount a protected host secret directory at `/run/secrets` and set the Bearer secret file path. Keep the legacy `DSH_TOKEN_REGISTER_URL` blank when using the JSON API; the runner rejects both modes being configured together. The registrar independently restricts source IP and allowed web port. Set `DSH_PUBLIC_URL` and `DSH_TRUSTED_HOST` to match the reverse-proxy route. `SSH_PORT` controls only the container's inbound sshd listener; it is unrelated to token registration, which no longer requires container-to-proxy SSH.

## DSH and Codex profile

`DSH_VERSION` defaults to `latest`. At each start, bootstrap resolves the selected NPM dist-tag or exact version, compares it with the installed version, and installs only when different. If the registry is unavailable, `latest` retains an already installed version; otherwise startup fails rather than silently selecting a version.

Bootstrap ensures that the persistent web profile includes `dsh-codex-subscription@3.1.4`. `/data` preserves the DSH home and profile across image upgrades; the shipped `dsh-home.patch.yml` is an intentionally empty generic home patch, not an appdata export. For the companion TTSwitch container on `dsh-private`, the service endpoint is `http://ttswitch:15723`; add the route-specific provider path in the private DSH profile, not this repository. The public template and image do not contain user-specific TTSwitch route settings. Keep your private appdata profile backed up and mounted at `/data` when upgrading images.

Global NPM installation allows install scripts only for `@deepseek-ai/dsh-subprocess-local`, `koffi`, `node-pty`, `@google/genai`, and `protobufjs`. No user-specific `meow-memory` allowlist entry is present.

## Persistence and security

Mount readable and writable persistent storage at `/data` and `/workspace`. Bootstrap requires `/data` to be readable and writable: it creates `/data/.ssh/authorized_keys` if missing, then copies that source file at startup to `/run/sshd/authorized_keys` with root ownership and mode `0600` for OpenSSH `StrictModes`. The copy is a startup snapshot; changes to the source file require a container restart before they affect SSH login. Bootstrap does not recursively change ownership or permissions under `/data`. Anyone able to modify `/data/.ssh/authorized_keys` can grant root-equivalent SSH access, so protect the mounted appdata. `/data/.dsh` holds DSH home data, profiles, plugin settings, and the home patch; `/workspace` holds work files.

At container startup, bootstrap checks for `ssh`, `sshd`, `ssh-keygen`, and `chpasswd`; if any are absent, it runs `apt-get update` and installs `openssh-client`, `openssh-server`, and `passwd`. The first start of a newly created container therefore requires access to the configured Debian package repositories. These runtime packages are in the container's writable layer and are lost when the container is recreated. `ssh-keygen -A` creates missing host keys after installation; keys are not baked into the image or persisted across container recreation, so recreating the container changes its SSH fingerprint. Verify a new fingerprint through a trusted channel instead of disabling host-key checking.

`SSH_PORT` sets the sshd listening port inside the container. It defaults to `22` and accepts canonical decimal ports without leading zeros from `1` through `65535`; the Docker host-to-container port mapping must match this value. SSH login is fixed to `root`; custom usernames are not supported. Bootstrap unsets any legacy `SSH_USERNAME` environment value. The persistent `/data/.ssh/authorized_keys` snapshot authorizes root.

Set `SSH_PASSWORD` to a non-empty value to set the root password and enable SSH password authentication. If it is unset or empty, password authentication is disabled; public-key authentication remains available in either mode. Bootstrap copies the exported value into an unexported shell variable, unsets `SSH_PASSWORD` before launching `chpasswd`, and sends the value to `chpasswd` only through stdin; it rejects line breaks and does not intentionally log the password or pass it in child-process environments. Unsetting it in bootstrap does not remove the original value from Docker's container configuration, which Docker administrators can inspect. Restrict Docker management access and protect the environment value.

The runner validates the sshd configuration, starts sshd and DSH as separately supervised process groups, and stops the peer when either service exits. It forwards container termination signals, escalates remaining process groups to SIGKILL after a grace period, and does not restart a failed service; configure any whole-container restart policy in the deployment layer.

Run without privileged mode, Docker socket mounts, or host-root mounts. Container-root is not host-root. The runner supports either the legacy optional `DSH_TOKEN_REGISTER_URL` HTTP `text/plain` registrar or the authenticated JSON proxy registrar configured by `DSH_PROXY_REGISTRATION_URL`, but rejects configuring both at once. Token query parameters are removed from the emitted launch URL before logging, and registration configuration is removed from the DSH child environment.

Do not put credentials, private routes, local hostnames/domains/IPs, or token values in this public source. Store deployment-specific provider and routing settings in private appdata. No LICENSE file is included; none was requested.

## Tests

See [`tests/README.md`](tests/README.md) for the static checks and Docker integration test, including required tools and exact commands. The integration test builds and runs a temporary container; it does not publish or deploy the image.
