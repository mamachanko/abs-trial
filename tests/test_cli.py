import pytest
from typer.testing import CliRunner

from asb.cli import app


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
