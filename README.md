# docker-for-dsh

A reusable DSH Web container based on `node:24.21.0-bookworm-slim`. The DSH process runs as container-root, Git is baked into the image, and apt remains available for runtime package setup. The container is not privileged and must not receive the Docker socket.

## Build and publish

Build from this directory:

```sh
docker build -t docker-for-dsh:local .
```

GitHub Actions publishes `ghcr.io/yunjies/docker-for-dsh:latest` and the source commit SHA tag for pushes to `main` or a manual dispatch. The workflow uses the repository-provided `GITHUB_TOKEN` with only contents-read and packages-write permissions. Set the GHCR package visibility to public for unauthenticated Unraid pulls.

For Unraid, load the template from <https://raw.githubusercontent.com/yunjies/docker-for-dsh/main/unraid/dsh.xml> and select the existing `dsh-private` Docker network. The template defaults to container name `dsh-sec`, host port `13081`, and appdata paths under `/mnt/user/appdata/dsh-sec`; choose a fixed private-network IP only when your token registrar or other consumers require it. If the registrar uses an IP allowlist, set `MyIP` and `DSH_BIND_HOST` to the same permitted address. Set `DSH_PUBLIC_URL` and `DSH_TRUSTED_HOST` to values that match the reverse-proxy route. Set `DSH_TOKEN_REGISTER_URL` only when a trusted launch-token registrar is configured.

## DSH and Codex profile

`DSH_VERSION` defaults to `latest`. At each start, bootstrap resolves the selected NPM dist-tag or exact version, compares it with the installed version, and installs only when different. If the registry is unavailable, `latest` retains an already installed version; otherwise startup fails rather than silently selecting a version.

Bootstrap ensures that the persistent web profile includes `dsh-codex-subscription@3.1.4`. `/data` preserves the DSH home and profile across image upgrades; the shipped `dsh-home.patch.yml` is an intentionally empty generic home patch, not an appdata export. For the companion TTSwitch container on `dsh-private`, the service endpoint is `http://ttswitch:15723`; add the route-specific provider path in the private DSH profile, not this repository. The public template and image do not contain user-specific TTSwitch route settings. Keep your private appdata profile backed up and mounted at `/data` when upgrading images.

Global NPM installation allows install scripts only for `@deepseek-ai/dsh-subprocess-local`, `koffi`, `node-pty`, `@google/genai`, and `protobufjs`. No user-specific `meow-memory` allowlist entry is present.

## Persistence and security

Mount persistent storage at `/data` and `/workspace`. `/data/.dsh` holds DSH home data, profiles, plugin settings, and the home patch; `/workspace` holds work files. Runtime package changes are in the container's writable layer and are lost when the container is recreated.

Run without privileged mode, Docker socket mounts, or host-root mounts. Container-root is not host-root. `DSH_TOKEN_REGISTER_URL` is optional and blank by default. When configured, the wrapper can post a valid launch token to that endpoint; token query parameters are removed from the emitted launch URL before logging, and the registration URL is not passed into the DSH process.

Do not put credentials, private routes, local hostnames/domains/IPs, or token values in this public source. Store deployment-specific provider and routing settings in private appdata. No LICENSE file is included; none was requested.

## Static checks

See [`tests/README.md`](tests/README.md). Checks are static and do not build, publish, install packages, or deploy the container.
