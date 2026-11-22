import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
from typer.testing import CliRunner

from asb import native
from asb.cli import app


@pytest.mark.parametrize(
    "status,body,exit_code,message",
    [
        (200, b'{"ready":true}', 0, "gateway ready"),
        (200, b'{"ready":false}', 1, "did not report ready"),
        (200, b'{"ready":1}', 1, "did not report ready"),
        (200, b"{}", 1, "did not report ready"),
        (200, b"[]", 1, "did not report ready"),
        (200, b"broken", 1, "Invalid gateway readiness response"),
        (503, b'{"ready":true}', 1, "HTTP 503"),
    ],
)
def test_status_at_gateway_url(status, body, exit_code, message):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(status if self.path == "/gateway/readyz" else 404)
            self.end_headers()
            self.wfile.write(body)

    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, args=(0.01,))
        thread.start()
        try:
            gateway = f"http://127.0.0.1:{server.server_port}/gateway/"
            result = CliRunner().invoke(app, ["status", "--gateway", gateway])
        finally:
            server.shutdown()
            thread.join()

    assert result.exit_code == exit_code, result.output
    assert message in result.output


@pytest.mark.parametrize(
    "body,exit_code,message",
    [
        ('{"ready":true}', 0, "OpenClaw gateway ready"),
        ('{"ready":"true"}', 1, "gateway is not ready"),
        ("broken", 1, "invalid readiness response"),
    ],
)
def test_status_reads_container_response(monkeypatch, body, exit_code, message):
    def docker_run(args, **kwargs):
        return subprocess.CompletedProcess(args, 0, stdout=body, stderr="")

    monkeypatch.setattr(native.subprocess, "run", docker_run)
    result = CliRunner().invoke(app, ["status", "--container", "test-lab"])
    assert result.exit_code == exit_code, result.output
    assert f"test-lab: {message}" in result.output


@pytest.mark.parametrize(
    "gateway", ["file:///tmp/test", "http://[", "http://localhost:bad"]
)
def test_status_rejects_invalid_gateway(gateway):
    result = CliRunner().invoke(app, ["openclaw", "status", "--gateway", gateway])
    assert result.exit_code == 2
    assert "gateway URL" in result.output


@pytest.mark.parametrize("args", [[], ["-h"], ["openclaw"], ["openclaw", "-h"]])
def test_help_lists_install_upgrade_and_status(args):
    result = CliRunner().invoke(app, args)
    assert result.exit_code == 0
    assert all(command in result.output for command in ("install", "upgrade", "status"))


def test_upgrade_rejects_non_version_before_contacting_docker():
    result = CliRunner().invoke(app, ["upgrade", "--to", "latest"])
    assert result.exit_code != 0
    assert "version" in result.output.lower() or "release" in result.output.lower()
