import re
import subprocess
from importlib.resources import files

from .readiness import is_ready

DEFAULT_VERSION = "2026.11.6"


def install(
    container: str, version: str = DEFAULT_VERSION, *, skip_local_model: bool = False
) -> str:
    """Bootstrap the Ubuntu lab and start its user-owned gateway."""
    return _run_install(
        container, "install", version, skip_local_model=skip_local_model
    )


def upgrade(container: str, to: str) -> str:
    """Upgrade the lab's OpenClaw package and restart its gateway."""
    return _run_install(container, "upgrade", to)


def _run_install(
    container: str, action: str, version: str, *, skip_local_model: bool = False
) -> str:
    if (
        re.fullmatch(r"[1-9][0-9]{3}\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version)
        is None
    ):
        raise ValueError("Expected an exact numeric OpenClaw release (YYYY.M.N).")
    operation = "Installation" if action == "install" else "Upgrade"
    try:
        subprocess.run(
            [
                "docker",
                "exec",
                "-i",
                "--user",
                "ubuntu",
                "--workdir",
                "/home/ubuntu",
                "--",
                container,
                "bash",
                "-s",
                "--",
                action,
                version,
                *(["--skip-local-model"] if skip_local_model else []),
            ],
            input="\n".join(
                files("asb").joinpath(script).read_text()
                for script in ("gateway.sh", "model.sh", "install.sh")
            ),
            text=True,
            check=True,
            timeout=1200,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"{operation} on {container} timed out.") from exc
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(
            f"{operation} on {container} failed. See the output above."
        ) from exc
    result = status(container)
    return f"{result} OpenClaw {version}."


def status(container: str) -> str:
    """Query the loopback-only gateway from inside its own network namespace."""
    try:
        result = subprocess.run(
            [
                "docker",
                "exec",
                "--user",
                "ubuntu",
                "--",
                container,
                "curl",
                "--silent",
                "--show-error",
                "--max-time",
                "5",
                "--fail",
                "http://127.0.0.1:18789/readyz",
            ],
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"{container}: status timed out.") from exc
    if result.returncode:
        raise RuntimeError(
            f"{container}: gateway unavailable. {result.stderr.strip() or result.stdout.strip()}"
        )
    try:
        ready = is_ready(result.stdout)
    except ValueError as exc:
        raise RuntimeError(f"{container}: invalid readiness response.") from exc
    if not ready:
        raise RuntimeError(f"{container}: gateway is not ready.")
    return f"{container}: OpenClaw gateway ready."
