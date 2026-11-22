import json
import logging
import subprocess
from pathlib import Path

log = logging.getLogger(__name__)
LAB = Path(__file__).resolve().parents[1] / "lab"


def docker(*args):
    return subprocess.check_output(["docker", *args], text=True, timeout=300).strip()


def test_native_install_on_clean_ubuntu():
    log.info("Starting a clean Ubuntu 24.04 container")
    image = docker("build", "--quiet", str(LAB))
    container = docker("run", "-d", "--init", image)
    try:
        log.info("Checking that Node and OpenClaw are absent in %s", container[:12])
        docker(
            "exec",
            container,
            "sh",
            "-ec",
            "! command -v node && ! command -v openclaw && test ! -e /home/ubuntu/.local/bin/openclaw",
        )
        install = ["asb", "install", "--container", container]
        log.info(
            "Running asb install: install Node, OpenClaw and the CPU model, then start the gateway"
        )
        subprocess.run(install, check=True, timeout=1500)
        prefix = "/home/ubuntu/.local"
        run = ["exec", "-u", "ubuntu", container]
        log.info("Checking the installed versions as the ubuntu user")
        node_version = docker(*run, f"{prefix}/tools/node/bin/node", "--version")
        log.info("Node reported %s", node_version)
        assert node_version == "v24.22.1"
        claw = f"{prefix}/bin/openclaw"
        claw_version = docker(*run, claw, "--version")
        log.info("%s", claw_version)
        assert "2026.11.6" in claw_version
        log.info("Validating the OpenClaw configuration")
        docker(*run, claw, "config", "validate")
        mode = docker(*run, claw, "config", "get", "gateway.mode")
        log.info("Configured gateway mode: %s", mode)
        assert mode == "local"

        status = ["asb", "status", "--container", container]
        ready = subprocess.check_output(status, timeout=15, text=True)
        log.info("asb status: %s", ready.strip())
        assert "gateway ready" in ready
        prompt = "What is the capital of France? Answer with just the name of the city."
        log.info("Asking the OpenClaw gateway: %s", prompt)
        turn = json.loads(
            docker(
                *run,
                claw,
                "agent",
                "--agent",
                "main",
                "--session-id",
                "asb-check",
                "--message",
                prompt,
                "--json",
                "--timeout",
                "150",
            )
        )
        assert turn["status"] == "ok", turn
        result = turn["result"]
        reply = " ".join(p["text"] for p in result["payloads"] if p.get("text"))
        model = result["meta"]["agentMeta"]
        log.info("Reply from %s/%s: %s", model["provider"], model["model"], reply)
        assert (model["provider"], model["model"]) == ("lab", "asb-local")
        assert model["usage"]["output"] > 0
        assert "paris" in reply.casefold(), reply
        log.info("Stopping the container and repeating asb status")
        docker("stop", "-t", "3", container)
        stopped = subprocess.run(
            status, capture_output=True, text=True, timeout=15, check=False
        )
        log.info("asb status exited %s: %s", stopped.returncode, stopped.stderr.strip())
        assert stopped.returncode == 1
        assert "gateway unavailable" in stopped.stderr
    finally:
        log.info("Removing test container %s", container[:12])
        docker("rm", "-fv", container)
