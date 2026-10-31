# Static checks

From the repository root, run only the requested syntax and well-formedness checks:

```sh
sh -n bootstrap.sh
sh -n tests/docker-integration.sh
node --check dsh-web-runner.mjs
DSH_SESSION_ID="${DSH_SESSION_ID:?set a session-<lowercase UUID>}" node --test tests/ssh-contract.test.mjs
python3 -c 'import xml.etree.ElementTree as ET; ET.parse("unraid/dsh.xml")'
```

The syntax checks cover shell parsing, JavaScript syntax, and XML parsing. `tests/ssh-contract.test.mjs` asserts the SSH/bootstrap and runner source contracts and includes deliberately defective fixtures that each contract predicate must reject. It does not execute a container, a real `sshd`, or actual child-process races; it is a static regression test, not runtime evidence for SSH authentication, host-key generation, external connectivity, or signal-driven cleanup.

## SSH authentication assertion fixtures

Run the assertion fixtures after setting `DSH_SESSION_ID` to a valid `session-<lowercase UUID>` and `DSH_TEST_SESSION_DIR` to that session's physical `.sessions/$DSH_SESSION_ID` directory inside the workspace ancestry; the script applies its normal UUID, symlink, and physical-containment guards before fixture writes.

```sh
DSH_SESSION_ID="${DSH_SESSION_ID:?set a session-<lowercase UUID>}" \
DSH_TEST_SESSION_DIR="${DSH_TEST_SESSION_DIR:?set the workspace .sessions/$DSH_SESSION_ID path}" \
  sh tests/docker-integration.sh --auth-fixtures
```

This mode runs locally without Docker or an SSH server. It exercises the same `assert_ssh_auth_outcome` helper used by E2E against synthetic marker files and server stderr samples; only fixture files beneath the validated session directory are created and removed. An enabled wrong password is accepted as an authentication rejection only with the password-specific `Permission denied` diagnostic and an AskPass marker; disabled-password mode requires the publickey-only denial without an AskPass marker. Reset, refused, timeout, no-route, KEX/banner errors, mixed `Permission denied` plus transport errors, missing markers, or successful SSH in a rejection mode must fail the assertion.

## Startup diagnostic fixtures

The startup/runner log allowlist can be exercised locally without Docker. It maps only known fixed bootstrap/runner messages to fixed diagnostic codes and emits validated component plus numeric exit status or signal for peer-close messages. Fixtures submit a failed-stage record for each of the 19 stage values currently set by `bootstrap.sh`; each must map to its normalized fixed diagnostic code. The current suite reports 45 log cases and 4 state cases, including rejection of unknown, overlong, secret-bearing stage values and invalid exit/state formats. Dynamic error details, file paths, URLs, tokens, passwords, keys, and raw log lines are never printed. Fixtures include known bootstrap/runner formats followed by randomized secret/path suffixes and unknown raw messages. These fixtures use only synthetic files in the validated session directory and never read real keys, `authorized_keys`, or environment secrets. Fixture input/output files are mode `0600` under the current session's validated `.sessions/$DSH_SESSION_ID/diagnostic-fixtures-*` directory and are removed on exit.

```sh
DSH_SESSION_ID="${DSH_SESSION_ID:?set a session-<lowercase UUID>}" \
DSH_TEST_SESSION_DIR="${DSH_TEST_SESSION_DIR:?set the workspace .sessions/$DSH_SESSION_ID path}" \
  sh tests/docker-integration.sh --diagnostic-fixtures
```

## Docker integration

Run the non-skipping end-to-end test from this repository root, with Docker Engine, `ssh`, `ssh-keygen`, `od`, `tr`, `awk`, `grep`, `cat`, and `stat` available; password login uses OpenSSH askpass and does not require `sshpass`. Supply an image tag that does not already exist; the script refuses to overwrite an existing image:

```sh
DSH_SESSION_ID="${DSH_SESSION_ID:?}" \
DSH_TEST_SESSION_DIR="${DSH_TEST_SESSION_DIR:-$PWD/.sessions/$DSH_SESSION_ID}" \
DSH_TEST_IMAGE="${DSH_TEST_IMAGE:?set a unique, unused image tag}" \
DSH_TEST_SSH_PORT="${DSH_TEST_SSH_PORT:-2222}" \
DSH_TEST_CONTAINER_SSH_PORT="${DSH_TEST_CONTAINER_SSH_PORT:-2223}" \
  sh tests/docker-integration.sh
```

The script accepts a valid `session-<lowercase UUID>` only, resolves `.sessions` and the per-session test directory physically, rejects symlink escapes, and performs these checks before creating test files. Its malformed-ID test uses command shims to prove rejection occurs before prerequisite checks or any test write. If this repository is nested inside a larger workspace, set `DSH_TEST_SESSION_DIR` to that workspace's `.sessions/$DSH_SESSION_ID`; otherwise the repository-root `.sessions/$DSH_SESSION_ID` is used. The test builds the explicitly tagged image, then probes the merged image before its normal entrypoint runs: OpenSSH `ssh` and `sshd` must be absent, with no baked host private key. The normal entrypoint must install missing OpenSSH client/server/account tools at runtime; after startup the test checks the tools and generated host key before attempting SSH. It silently retries while the runtime host-key file is absent or its `docker exec test -s` probe fails; once present, a read or format error emits a fixed diagnostic without printing key material. It creates two uniquely named containers whose names include the session UUID and a random suffix. It refuses name collisions and records a successful `docker create` result as the immutable cleanup ID only after validating its full 64-character lowercase-hex form; it never removes by a container name. Published SSH is bound only to `127.0.0.1:$DSH_TEST_SSH_PORT` (default `2222`). Both containers authenticate as the fixed `root` user; `SSH_USERNAME` is unsupported. The password-enabled test sets a non-default internal `SSH_PORT`, and Docker maps the loopback host port to that container port. The password-disabled test omits `SSH_PORT` to verify the default `22`. The test verifies runtime client/server installation, root key login, configured-root-password login, incorrect-password rejection, password-disabled rejection, runtime host-key generation, and graceful stop for both authentication modes. Immediately before each stop, the container must still report `Running=true`; premature exit is a failure and does not get masked by `docker stop`. A successful stop must finish in less than 15 seconds with exit code `0`, PID `0`, and `Running=false`. It also requires the runner's `graceful shutdown requested by SIGTERM` log marker and rejects its actual `exited (` peer-exit diagnostic; the marker assertions distinguish signal-driven shutdown from a natural peer exit. The test also checks that host PIDs from `docker top` are no longer live (or are zombies/exited), and that neither test password appears in container logs. Password authentication uses OpenSSH `SSH_ASKPASS`/`SSH_ASKPASS_REQUIRE=force`; `sshpass` is not required.

Test keys, password material, and persistent test data remain under the validated `.sessions/$DSH_SESSION_ID` directory; the script does not delete them. Askpass password files use mode `0600`. The test supplies the ephemeral password to Docker as an environment variable, so Docker administrators can inspect it in the container configuration until that test container is removed; the script does not place password values in command arguments or logs. The built image is also retained under `DSH_TEST_IMAGE`; the caller must remove only that exact tag when appropriate. The script does not prune or remove images. When run from a temporary remote build copy, the coordinating agent is responsible for cleaning only the exact temporary directory and image tag it created. On failures, the script never prints raw `docker logs`: it reports only validated numeric container `ExitCode`/`Pid`, boolean `OOMKilled`, and boolean Docker `State.Error` presence, plus fixed diagnostic codes from strict message allowlists; allowlisted child-exit records expose only a validated component and numeric exit code or signal name. Unknown log lines produce only `no allowlisted diagnostic`. Dynamic error text, paths, URLs, tokens, passwords, and `State.Error` contents are never emitted. The test requires apt repository access during container startup for OpenSSH installation and npm registry access for DSH resolution/installation and profile setup. It does not silently skip when Docker or another prerequisite is absent: it exits nonzero. These integration behaviors are not proven by the static checks.
