import json
import logging
import subprocess
from pathlib import Path
from uuid import uuid4

import pytest

log = logging.getLogger(__name__)
LAB = Path(__file__).resolve().parents[1] / "lab"
FACADE = Path(__file__).parent / "fixtures" / "model-facade.cjs"
RECEIPTS = "/home/ubuntu/facade-receipts.jsonl"


def docker(*args):
    result = subprocess.run(
        ["docker", *args],
        text=True,
        stdout=subprocess.PIPE,
        timeout=300,
        check=False,
    )
    assert result.returncode == 0, (
        f"docker {args[0]} exited {result.returncode}\n{result.stdout}"
    )
    return result.stdout.strip()


@pytest.fixture
def ubuntu_lab():
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
        yield container
    finally:
        log.info("Removing test container %s", container[:12])
        docker("rm", "-fv", container)


def agent_turn(container, prompt, session_id):
    run = ["exec", "-u", "ubuntu", container]
    claw = "/home/ubuntu/.local/bin/openclaw"
    log.info("Asking the OpenClaw gateway: %s", prompt)
    turn = json.loads(
        docker(
            *run,
            claw,
            "agent",
            "--agent",
            "main",
            "--session-id",
            session_id,
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
    return reply, model


def install_with_facade(container, *install_args):
    log.info("Installing OpenClaw without model weights")
    subprocess.run(
        [
            "asb",
            "install",
            "--skip-local-model",
            "--container",
            container,
            *install_args,
        ],
        check=True,
        timeout=1500,
    )
    run = ["exec", "-u", "ubuntu", container]
    docker(*run, "test", "!", "-e", "/home/ubuntu/.local/share/asb-model")
    script = "/tmp/model-facade.cjs"
    docker("cp", str(FACADE), f"{container}:{script}")
    docker(
        "exec",
        "-d",
        "-u",
        "ubuntu",
        container,
        "/home/ubuntu/.local/tools/node/bin/node",
        script,
        RECEIPTS,
    )
    models = docker(
        *run,
        "curl",
        "-fsS",
        "--retry",
        "10",
        "--retry-connrefused",
        "--retry-delay",
        "1",
        "--max-time",
        "3",
        "-H",
        "Authorization: Bearer asb-local",
        "http://127.0.0.1:18080/v1/models",
    )
    assert [item["id"] for item in json.loads(models)["data"]] == ["asb-local"]


def assert_facade_reply(container):
    nonce = uuid4().hex
    reply, _ = agent_turn(container, f"asb-check-{nonce}", f"asb-test-{nonce}")
    events = docker("exec", "-u", "ubuntu", container, "cat", RECEIPTS)
    receipts = [
        event["receipt"]
        for event in map(json.loads, events.splitlines())
        if event["nonce"] == nonce
    ]
    assert len(receipts) == 1, receipts
    assert reply == receipts[0]


@pytest.mark.real_model
def test_native_install_on_clean_ubuntu(ubuntu_lab):
    container = ubuntu_lab
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
    props = json.loads(
        docker(
            *run,
            "curl",
            "-fsS",
            "-H",
            "Authorization: Bearer asb-local",
            "http://127.0.0.1:18080/props",
        )
    )
    weights = Path(props["model_path"]).name
    log.info("Loaded model weights: %s", weights)
    assert weights == "LFM2.5-350M-Q4_K_M.gguf"
    reply, model = agent_turn(
        container,
        "What is the capital of France? Answer with just the name of the city.",
        "asb-check",
    )
    assert "paris" in reply.casefold(), reply
    assert model["usage"]["output"] > 0
    log.info("Stopping the container and repeating asb status")
    docker("stop", "-t", "3", container)
    stopped = subprocess.run(
        status, capture_output=True, text=True, timeout=15, check=False
    )
    log.info("asb status exited %s: %s", stopped.returncode, stopped.stderr.strip())
    assert stopped.returncode == 1
    assert "gateway unavailable" in stopped.stderr


def test_invalid_gateway_mode_is_rejected(ubuntu_lab):
    log.info("Installing OpenClaw before testing a configuration change")
    install_with_facade(ubuntu_lab)
    config = [
        "exec",
        "-u",
        "ubuntu",
        ubuntu_lab,
        "/home/ubuntu/.local/bin/openclaw",
        "config",
    ]
    assert docker(*config, "get", "gateway.mode") == "local"

    log.info("Trying to set gateway.mode to sideways")
    result = subprocess.run(
        ["docker", *config, "set", "gateway.mode", "sideways"],
        check=False,
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert result.returncode == 1, (result.stdout, result.stderr)
    assert "invalid config" in result.stderr.lower(), result.stderr
    assert "gateway.mode" in result.stderr, result.stderr
    log.info("OpenClaw rejected the change: %s", result.stderr.strip())

    assert docker(*config, "get", "gateway.mode") == "local"
    docker(*config, "validate")
    ready = subprocess.check_output(
        ["asb", "status", "--container", ubuntu_lab], text=True, timeout=15
    )
    assert "gateway ready" in ready
    assert_facade_reply(ubuntu_lab)


def assert_gateway_version(container, expected):
    probe = json.loads(
        docker(
            "exec",
            "-u",
            "ubuntu",
            container,
            "/home/ubuntu/.local/bin/openclaw",
            "gateway",
            "probe",
            "--timeout",
            "30000",
            "--json",
        )
    )
    versions = [
        t["server"]["version"]
        for t in probe["targets"]
        if t["url"].rstrip("/") == "ws://127.0.0.1:18789" and t["connect"]["ok"]
    ]
    log.info("Live gateway reported %s", versions)
    assert versions == [expected]


def test_upgrade_preserves_lab_and_routes_to_provider(ubuntu_lab):
    container = ubuntu_lab
    run = ["exec", "-u", "ubuntu", container]
    claw = "/home/ubuntu/.local/bin/openclaw"
    log.info("Installing the upgrade baseline, OpenClaw 2026.11.5")
    install_with_facade(container, "--version", "2026.11.5")
    assert_gateway_version(container, "2026.11.5")
    assert_facade_reply(container)

    log.info("Saving a workspace note and a custom OpenClaw setting before the upgrade")
    workspace = "/home/ubuntu/.openclaw/workspace"
    docker(*run, "mkdir", "-p", workspace)
    docker(
        *run,
        "sh",
        "-c",
        'echo "saved before upgrade" > "$1/upgrade-note.txt"',
        "_",
        workspace,
    )
    docker(*run, claw, "config", "set", "agents.defaults.userTimezone", "Europe/Berlin")

    log.info("Upgrading the same lab to OpenClaw 2026.11.6")
    subprocess.run(
        ["asb", "openclaw", "upgrade", "--container", container, "--to", "2026.11.6"],
        check=True,
        timeout=1500,
    )
    assert_gateway_version(container, "2026.11.6")
    assert (
        docker(*run, "cat", f"{workspace}/upgrade-note.txt") == "saved before upgrade"
    )
    assert (
        docker(*run, claw, "config", "get", "agents.defaults.userTimezone")
        == "Europe/Berlin"
    )
    assert_facade_reply(container)


def test_unavailable_upgrade_keeps_original_gateway_serving(ubuntu_lab):
    log.info("Installing the baseline and verifying its live gateway version")
    baseline = "2026.11.5"
    install_with_facade(ubuntu_lab, "--version", baseline)
    assert_gateway_version(ubuntu_lab, baseline)

    missing = "9999.1.1"
    log.info("Requesting unpublished OpenClaw release %s", missing)
    result = subprocess.run(
        ["asb", "openclaw", "upgrade", "--container", ubuntu_lab, "--to", missing],
        capture_output=True,
        text=True,
        check=False,
        timeout=180,
    )
    assert result.returncode == 1, (result.stdout, result.stderr)
    assert missing in result.stderr, result.stderr
    assert "E404" in result.stderr, result.stderr
    assert_gateway_version(ubuntu_lab, baseline)
    assert_facade_reply(ubuntu_lab)
