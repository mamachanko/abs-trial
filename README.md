# Agent Sandbox (ASB)

ASB is a Python CLI for installing and upgrading OpenClaw on a disposable Ubuntu machine. Start with clean Linux, ask a local model a question, then upgrade OpenClaw in place. CI runs the same commands and checks that the gateway can still answer.

Docker supplies the Ubuntu machine that stands in for a VPS. The image build uses `apt-get` for OS prerequisites such as Git and curl. ASB runs on the host and installs Node, OpenClaw, and the CPU model **inside the running container** as the `ubuntu` user. [Lab Dockerfile](lab/Dockerfile)

## Watch a clean install answer its first question

Use an x86_64 Linux Docker host with internet access for the initial downloads. Install [uv](https://docs.astral.sh/uv/getting-started/installation/) if your shell can't find it. Run the examples from the repository root. For a fresh checkout, use `git clone https://github.com/mamachanko/abs-trial.git asb` and `cd asb`.

```sh
uv sync --locked --python 3.12
uv run --locked pytest -v -s --log-cli-level=INFO \
  tests/test_openclaw.py::test_native_install_on_clean_ubuntu
```

Pytest creates its own Ubuntu 24.04 container and checks that Node and OpenClaw are absent. It calls `asb install`, checks the gateway, and asks for the capital of France. A successful turn produces a log entry like this.

```text
Reply from lab/asb-local: The capital of France is Paris.
```

The test checks the answer, the provider and model ID, and a positive output token count. It then stops the container, checks that `asb status` reports the outage, and removes the lab. `--log-cli-level=INFO` shows what pytest is checking. `-s` also shows the installer output.

## Keep a lab to use yourself

Build the Ubuntu image, start a container named `asb-lab`, and install OpenClaw.

```sh
docker build -t asb-ubuntu-lab lab
docker run -d --init --name asb-lab asb-ubuntu-lab
uv run --locked asb install
uv run --locked asb status
```

Expect `asb-lab: OpenClaw gateway ready.` The default install includes Node 24.22.1, OpenClaw 2026.11.6, and LiquidAI LFM2.5-350M (229 MB of model weights). The gateway listens on port 18789 and sends inference requests to llama.cpp on port 18080. Both listen on loopback inside the container.

Send a prompt with the installed OpenClaw CLI.

```sh
docker exec -u ubuntu asb-lab /home/ubuntu/.local/bin/openclaw agent \
  --agent main --message 'What is the capital of France? Answer with just the name of the city.' --json
```

Read the reply in `result.payloads`. Under `result.meta.agentMeta`, the provider should be `lab` and the model should be `asb-local`.

### Upgrade in place

To try the upgrade that CI tests, start a second container from the image you built above.

```sh
docker run -d --init --name asb-upgrade-lab asb-ubuntu-lab
uv run --locked asb install --container asb-upgrade-lab --version 2026.11.5
uv run --locked asb upgrade --container asb-upgrade-lab --to 2026.11.6
uv run --locked asb status --container asb-upgrade-lab
```

Use an exact release with `--to`. ASB checks that the release is available before stopping the gateway. After installing the package, ASB confirms the **running gateway** reports the requested version. OpenClaw keeps its configuration and workspace in the same container.

### Inspect, restart, or remove a lab

- **Commands.** Run `uv run --locked asb -h` for help. The commands are `install`, `upgrade`, and `status`. Each also works under `asb openclaw`.
- **Target.** ASB defaults to `asb-lab`. Select another running container with `--container NAME` or set `ASB_CONTAINER`. To check a gateway already reachable from the host, run `uv run --locked asb status --gateway URL`. ASB requests `/readyz`.
- **Logs.** Inspect the gateway and inference processes separately.

  ```sh
  docker exec -u ubuntu asb-lab tail -n 30 /home/ubuntu/.local/state/asb/gateway.log
  docker exec -u ubuntu asb-lab tail -n 30 /home/ubuntu/.local/share/asb-model/server.log
  ```

- **Restart.** A stopped container keeps its files. For the default lab, run `docker start asb-lab`, then `uv run --locked asb install` to start both processes again. If you installed a different release, pass its version to `install --version`.
- **Older Qwen labs.** Rerun `uv run --locked asb install` in the default lab to switch its local model to LFM2.5.
- **Cleanup.** Removing a container deletes its workspace, configuration, and downloaded weights. Remove each lab when you finish with it.

  ```sh
  docker rm -f asb-lab
  docker rm -f asb-upgrade-lab
  ```

## What CI verifies

Each integration test gets a fresh container and drives the installed tools. [Integration tests](tests/test_openclaw.py)

| Scenario | What must happen |
| --- | --- |
| Clean install | ASB installs Node and OpenClaw. The local model answers through the gateway. Stopping the container makes `asb status` fail. |
| Invalid configuration | OpenClaw rejects `gateway.mode=sideways`, retains `local`, and the gateway stays ready. |
| In-place upgrade | The live gateway moves from 2026.11.5 to 2026.11.6. A workspace note and a custom timezone survive, and the local model answers a fresh prompt. |
| Unavailable release | ASB rejects the upgrade. The gateway still reports its original version and answers through the local model. |

To watch just the two upgrade cases, run `uv run --locked pytest -v -s --log-cli-level=INFO -k upgrade tests/test_openclaw.py`.

Run the same lint, format, and test checks as GitHub Actions. Pytest reports Python line and branch coverage. [CI workflow](.github/workflows/ci.yml)

```sh
uv run --locked ruff check .
uv run --locked ruff format --check .
uv run --locked pytest -q
```
