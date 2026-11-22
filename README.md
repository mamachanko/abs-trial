# Agent Sandbox

ASB installs OpenClaw and a small local language model on an Ubuntu 24.04
lab machine. The machine is a Docker container. Inside it, the OpenClaw gateway
listens on loopback port 18789 and uses llama.cpp on loopback port 18080 to run
LiquidAI LFM2.5-350M on the CPU. The lab downloads the 229 MB Q4_K_M weights.

## Install and send a message

From this directory on an x86_64 Linux Docker host with uv:

```sh
# Prepare the disposable Ubuntu machine and its OS prerequisites.
docker build -t asb-ubuntu-lab lab
docker run -d --init --name asb-lab asb-ubuntu-lab

# Install as the container's ubuntu user.
uv run asb install
uv run asb status

# Send a turn through the installed gateway to its default model.
docker exec -u ubuntu asb-lab /home/ubuntu/.local/bin/openclaw agent \
  --agent main --message "What is the capital of France? Answer with just the name of the city."
```

Add `--json` to the agent command to inspect the reply, model ID, provider,
and token usage. Use `uv run asb -h` to list commands. Select a different
container with `--container NAME` on install or status.

The image build installs OS packages. `asb install` runs as the unprivileged
`ubuntu` user. It installs Node 24.22.1, OpenClaw 2026.11.6, the CPU inference
server, and model weights, then configures and starts both services. The first
install downloads the runtime and weights. The lab agent uses `lab/asb-local`
as its default model, with an empty fallback list and tools disabled for text
interaction. `asb status` reports gateway readiness.

To switch an existing ASB lab from Qwen to LFM2.5, rerun `uv run asb install`.
The lab keeps its configuration and downloads in the container. After a
container restart, rerun `uv run asb install` to start the processes.
To delete the lab and its installed state, run `docker rm -f asb-lab`.

## Watch the integration test

```sh
uv run --locked pytest -v --log-cli-level=INFO tests/test_openclaw.py
```

Pytest builds the lab image and creates a fresh container. It checks that Node
and OpenClaw are absent, invokes ASB, checks the versions and configuration, and
sends a geography question through the gateway. It checks that the reply names Paris, local
provider and model ID, and positive output token count. Finally it stops the
container, checks that ASB reports the outage, and removes the container.
Add `-s` to see installer output. Run `uv run --locked pytest` for the full suite.
