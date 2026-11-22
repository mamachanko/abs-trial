import json
from http.client import HTTPException
from typing import Annotated
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import urlopen

import typer

from . import native

_HELP_SETTINGS = {"help_option_names": ["-h", "--help"]}
app = typer.Typer(
    help="Install and inspect OpenClaw in a disposable Ubuntu lab.",
    epilog="Prepare the Ubuntu lab using the README, then run `uv run asb install`.",
    context_settings=_HELP_SETTINGS,
)
openclaw = typer.Typer(
    help="Install OpenClaw or check its status.",
    context_settings=_HELP_SETTINGS,
)
app.add_typer(openclaw, name="openclaw")

Container = Annotated[
    str,
    typer.Option(
        "--container",
        "-c",
        envvar="ASB_CONTAINER",
        help="Name of the running Ubuntu container.",
    ),
]


@app.callback(invoke_without_command=True)
def main(ctx: typer.Context):
    if ctx.invoked_subcommand is None:
        typer.echo(ctx.get_help())


@openclaw.callback(invoke_without_command=True)
def openclaw_main(ctx: typer.Context):
    if ctx.invoked_subcommand is None:
        typer.echo(ctx.get_help())


@app.command()
@openclaw.command()
def install(
    container: Container = "asb-lab",
    version: Annotated[
        str, typer.Option(help="Exact OpenClaw release to install (YYYY.M.N).")
    ] = native.DEFAULT_VERSION,
):
    """Install and start OpenClaw in a running Ubuntu container."""
    try:
        result = native.install(container, version)
    except (RuntimeError, OSError, ValueError) as exc:
        typer.echo(f"OpenClaw installation failed: {exc}", err=True)
        raise typer.Exit(1) from exc
    typer.echo(result)


@app.command()
@openclaw.command()
def upgrade(
    to: Annotated[
        str, typer.Option("--to", help="Exact target OpenClaw release (YYYY.M.N).")
    ],
    container: Container = "asb-lab",
):
    """Upgrade OpenClaw while preserving the lab configuration and workspace."""
    try:
        result = native.upgrade(container, to)
    except (RuntimeError, OSError, ValueError) as exc:
        typer.echo(f"OpenClaw upgrade failed: {exc}", err=True)
        raise typer.Exit(1) from exc
    typer.echo(result)


@app.command()
@openclaw.command()
def status(
    ctx: typer.Context,
    container: Container = "asb-lab",
    gateway: Annotated[
        str | None,
        typer.Option(help="Check readiness at this HTTP(S) gateway URL instead."),
    ] = None,
):
    """Check OpenClaw in a container or at a gateway URL."""
    if gateway is not None:
        if ctx.get_parameter_source("container").name == "COMMANDLINE":
            raise typer.BadParameter("Use either --gateway or --container, not both.")
        _gateway_status(gateway)
        return

    try:
        result = native.status(container)
    except (RuntimeError, OSError, ValueError) as exc:
        typer.echo(f"OpenClaw status check failed: {exc}", err=True)
        raise typer.Exit(1) from exc
    typer.echo(result)


def _gateway_status(gateway: str):
    try:
        address = urlsplit(gateway)
        if address.scheme not in {"http", "https"} or not address.hostname:
            raise ValueError("missing scheme or hostname")
        _ = address.port  # Validate the port before making the request.
    except ValueError as exc:
        raise typer.BadParameter(
            "Expected an http:// or https:// gateway URL.", param_hint="--gateway"
        ) from exc
    try:
        with urlopen(gateway.rstrip("/") + "/readyz", timeout=5) as response:
            payload = json.load(response)
    except HTTPError as exc:
        typer.echo(f"Gateway readiness check returned HTTP {exc.code}.", err=True)
        raise typer.Exit(1) from exc
    except (OSError, HTTPException) as exc:
        typer.echo(f"Gateway unreachable: {exc}", err=True)
        raise typer.Exit(1) from exc
    except ValueError as exc:
        typer.echo("Invalid gateway readiness response.", err=True)
        raise typer.Exit(1) from exc

    if not isinstance(payload, dict) or payload.get("ready") is not True:
        typer.echo("Gateway did not report ready.", err=True)
        raise typer.Exit(1)
    typer.echo("OpenClaw gateway ready.")
