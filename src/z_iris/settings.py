"""The live configuration, shared by every stream and the output."""

from __future__ import annotations

import threading

from z_iris.config import Config


class Settings:
    def __init__(self, config: Config) -> None:
        self._config = config
        self._lock = threading.Lock()

    @property
    def config(self) -> Config:
        with self._lock:
            return self._config
