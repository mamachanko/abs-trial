import json
import subprocess
from importlib.resources import files


def install(container: str) -> str:
    """Bootstrap the Ubuntu lab and start its user-owned gateway."""
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
            ],
            input=files("asb").joinpath("install.sh").read_text(),
            text=True,
            check=True,
            timeout=1200,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"Installation on {container} timed out.") from exc
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(
            f"Installation on {container} failed. See the output above."
        ) from exc
    return status(container)


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
        reply = json.loads(result.stdout)
    except ValueError as exc:
        raise RuntimeError(f"{container}: invalid readiness response.") from exc
    if not isinstance(reply, dict) or reply.get("ready") is not True:
        raise RuntimeError(f"{container}: gateway is not ready.")
    return f"{container}: OpenClaw gateway ready."
