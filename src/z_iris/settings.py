"""The live configuration, shared by every stream and the output."""

from __future__ import annotations

import threading
from dataclasses import replace
from pathlib import Path

from z_iris.config import Config, ConfigError, load_config

RESTART_MESSAGE = "servers changed, restart z-iris"


class Settings:
    """Holds the current Config and swaps it when the file changes.

    A file that does not parse never replaces a good config.
    """

    def __init__(self, config: Config, path: Path | None = None) -> None:
        self._config = config
        self._path = path
        self._lock = threading.Lock()
        self._mtime = self._stat()
        self._error: str | None = None

    @property
    def config(self) -> Config:
        with self._lock:
            return self._config

    @property
    def error(self) -> str | None:
        with self._lock:
            return self._error

    def _stat(self) -> float | None:
        if self._path is None:
            return None
        try:
            return self._path.stat().st_mtime
        except OSError:
            return None

    def reload(self, force: bool = False) -> str | None:
        """Re-read the file if it changed. Return the current problem or None."""
        if self._path is None:
            return None
        mtime = self._stat()
        if not force and mtime == self._mtime:
            return self.error
        try:
            new = load_config(self._path)
        except ConfigError as error:
            return self._set(self._config, str(error))
        except Exception as error:  # a bad edit must never stop streaming
            return self._set(self._config, f"cannot read config: {error}")

        old = self._config
        identity = [(s.name, s.zuliprc) for s in new.servers]
        if identity != [(s.name, s.zuliprc) for s in old.servers]:
            return self._set(replace(new, servers=old.servers), RESTART_MESSAGE)
        return self._set(new, None)

    def _set(self, config: Config, error: str | None) -> str | None:
        self._mtime = self._stat()
        with self._lock:
            self._config = config
            self._error = error
        return error
