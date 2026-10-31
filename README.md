# docker-for-dsh

A reusable DSH Web container based on `node:24.21.0-bookworm-slim`. The DSH process runs as container-root, Git is baked into the image, and apt remains available for runtime package setup. The container is not privileged and must not receive the Docker socket.

## Build and publish

Build from this directory:

```sh
docker build -t docker-for-dsh:local .
```

GitHub Actions publishes `ghcr.io/yunjies/docker-for-dsh:latest` and the source commit SHA tag for pushes to `main` or a manual dispatch. The workflow uses the repository-provided `GITHUB_TOKEN` with only contents-read and packages-write permissions. Set the GHCR package visibility to public for unauthenticated Unraid pulls.

For Unraid, load the template from <https://raw.githubusercontent.com/yunjies/docker-for-dsh/main/unraid/dsh.xml> and select the existing `dsh-private` Docker network. The template defaults to container name `dsh-sec`, host port `13081`, and appdata paths under `/mnt/user/appdata/dsh-sec`; choose a fixed private-network IP only when your token registrar or other consumers require it. If the registrar uses an IP allowlist, set `MyIP` and `DSH_BIND_HOST` to the same permitted address. Set `DSH_PUBLIC_URL` and `DSH_TRUSTED_HOST` to values that match the reverse-proxy route. Set `DSH_TOKEN_REGISTER_URL` only when a trusted launch-token registrar is configured. `SSH_PORT` selects the port that sshd listens on inside the container (default `22`, valid range `1–65535`). Docker must separately map an unused host TCP port to that container port; for `SSH_PORT=22`, an example is `2222:22`. The image's `EXPOSE 22` is metadata for the default only and does not publish a host port.

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

Run without privileged mode, Docker socket mounts, or host-root mounts. Container-root is not host-root. `DSH_TOKEN_REGISTER_URL` is optional and blank by default. When configured, the wrapper can post a valid launch token to that endpoint; token query parameters are removed from the emitted launch URL before logging, and the registration URL is not passed into the DSH process.

Do not put credentials, private routes, local hostnames/domains/IPs, or token values in this public source. Store deployment-specific provider and routing settings in private appdata. No LICENSE file is included; none was requested.

## Tests

See [`tests/README.md`](tests/README.md) for the static checks and Docker integration test, including required tools and exact commands. The integration test builds and runs a temporary container; it does not publish or deploy the image.
