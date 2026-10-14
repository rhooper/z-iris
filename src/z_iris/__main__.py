"""z-iris command line."""

from __future__ import annotations

import argparse
import subprocess
import sys
import threading
from pathlib import Path

from z_iris.config import DEFAULT_PATH, Config, ConfigError, load_config
from z_iris.output import DryRunOutput, RealOutput
from z_iris.settings import Settings
from z_iris.stream import Controls, ServerStream, StatusBoard


def _probe(config: Config) -> int:
    import zulip

    for server in config.servers:
        client = zulip.Client(config_file=str(server.zuliprc))
        reply = client.register(
            event_types=["message", "subscription", "user_topic", "muted_topics"],
            apply_markdown=False,
        )
        print(f"{server.name}: result={reply.get('result')} base_url={client.base_url}")
        if reply.get("result") == "success":
            print("  keys:", ", ".join(sorted(reply)))
            for key in ("subscriptions", "user_topics", "muted_topics"):
                if key in reply:
                    print(f"  {key}: {len(reply[key])}")
            client.deregister(reply["queue_id"])
        else:
            print("  error:", reply.get("msg"))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="z-iris")
    parser.add_argument("--config", type=Path, default=DEFAULT_PATH)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print what would notify, play nothing; implies --headless",
    )
    parser.add_argument("--headless", action="store_true", help="no menubar app")
    parser.add_argument("command", nargs="?", choices=["probe", "edit"])
    args = parser.parse_args(argv)

    try:
        config = load_config(args.config)
    except ConfigError as error:
        print(f"z-iris: {error}", file=sys.stderr)
        return 2

    if args.command == "probe":
        return _probe(config)

    if args.command == "edit":
        from z_iris.webui import EditorServer

        editor = EditorServer(Settings(config, args.config), args.config)
        url = editor.start()
        print(f"z-iris editor: {url}  (Ctrl-C to stop)")
        subprocess.run(["open", url], check=False)
        try:
            threading.Event().wait()
        except KeyboardInterrupt:
            pass
        return 0

    controls = Controls()
    board = StatusBoard()
    settings = Settings(config, args.config)
    output = DryRunOutput(settings) if args.dry_run else RealOutput(settings)
    streams = [ServerStream(s, settings, output, controls, board) for s in config.servers]
    for stream in streams:
        stream.start()

    last_error = None
    if args.dry_run or args.headless:
        try:
            while True:
                error = settings.reload()
                if error and error != last_error:
                    print(f"z-iris: config: {error}", file=sys.stderr)
                last_error = error
                threading.Event().wait(1)
        except KeyboardInterrupt:
            pass
        return 0

    from z_iris.menubar import run_menubar

    run_menubar(settings, args.config, controls, board)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
