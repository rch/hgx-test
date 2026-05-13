"""Patch harbor's DockerEnvironment.preflight for podman-on-Linux.

The preflight runs `subprocess.run(["docker", "info"], check=True)`.  On Linux
without a systemd user session (e.g. `su -` inside SSH) `docker info` via the
podman shim can exit non-zero even though the podman socket is healthy.

If DOCKER_HOST points to an existing socket we skip the subprocess check
entirely — the socket being present is sufficient evidence that the daemon is
reachable.

Pinned to harbor 0.5.0.  If DockerEnvironment.preflight changes signature this
will fail loudly at import time.
"""

import inspect
import os
import shutil
import subprocess

from harbor.environments.docker.docker import DockerEnvironment

# Verify we're patching the expected method signature.
sig = inspect.signature(DockerEnvironment.preflight.__func__)
assert list(sig.parameters) == ["cls"], (
    f"harbor DockerEnvironment.preflight signature changed: {sig}"
)


@classmethod  # type: ignore[misc]
def _preflight(cls) -> None:
    if not shutil.which("docker"):
        raise SystemExit(
            "Docker is not installed or not on PATH. "
            "Please install Docker and try again."
        )
    # If DOCKER_HOST points at an existing socket, accept it directly.
    docker_host = os.environ.get("DOCKER_HOST", "")
    if docker_host.startswith("unix://"):
        sock = docker_host[len("unix://"):]
        if os.path.exists(sock):
            return
    try:
        subprocess.run(
            ["docker", "info"],
            capture_output=True,
            timeout=10,
            check=True,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        raise SystemExit(
            "Docker daemon is not running. Please start Docker and try again."
        )


DockerEnvironment.preflight = _preflight
