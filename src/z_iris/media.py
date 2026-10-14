"""Pick a local image for a notification: the first image in a message, else the avatar.

Every network step is bounded (timeouts, size caps) and any failure yields None.
Zulip credentials are only ever sent to the server's own host.
"""

from __future__ import annotations

import hashlib
import os
import re
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from urllib.parse import urljoin, urlparse

IMAGE_EXTS = ("png", "jpg", "jpeg", "gif", "webp")
_EXT = "|".join(IMAGE_EXTS)

_FENCE = re.compile(r"```.*?(?:```|\Z)", re.S)
# Alternatives are tried left to right at each position: image syntax, then
# links to image files, then bare image URLs.
_PATTERN = re.compile(
    r"!\[[^\[\]]*\]\(\s*<?(?P<img>[^()\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)"
    r"|\[[^\[\]]*\]\(\s*<?(?P<link>[^()\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)"
    r"|(?P<bare>https?://[^\s<>()\[\]]+)",
    re.I,
)
_IMAGE_PATH = re.compile(rf"\.(?:{_EXT})$", re.I)


def _has_image_ext(url: str) -> bool:
    return bool(_IMAGE_PATH.search(urlparse(url).path))


def _web_or_relative(url: str) -> bool:
    scheme = urlparse(url).scheme.lower()
    return scheme in ("http", "https") or (not scheme and url.startswith("/"))


def extract_image_urls(content: str) -> list[str]:
    """Image URLs in Zulip markdown, in order, deduplicated. May be relative."""
    found: list[str] = []
    for m in _PATTERN.finditer(_FENCE.sub("", content or "")):
        if m.group("img"):
            url, needs_ext = m.group("img"), False
        elif m.group("link"):
            url, needs_ext = m.group("link"), True
        else:
            url, needs_ext = m.group("bare").rstrip(".,;:!?'\""), True
        if not _web_or_relative(url) or (needs_ext and not _has_image_ext(url)):
            continue
        if url not in found:
            found.append(url)
    return found


class ClientRegistry:
    """Thread-safe server name -> Zulip client."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._clients: dict[str, object] = {}

    def set(self, server_name: str, client) -> None:
        with self._lock:
            self._clients[server_name] = client

    def get(self, server_name: str):
        with self._lock:
            return self._clients.get(server_name)


# Shared by stream.py (writer) and the notifier's ImageResolver (reader).
default_registry = ClientRegistry()


class HttpError(Exception):
    pass


_AUTH_PATHS = ("/user_uploads/", "/user_avatars/", "/thumbnail")


def _origin(url: str):
    """(scheme, hostname, port) with the default port filled in, or None."""
    try:
        parsed = urlparse(url)
        scheme = parsed.scheme.lower()
        port = parsed.port or {"http": 80, "https": 443}.get(scheme)
    except ValueError:
        return None
    if scheme not in ("http", "https") or not parsed.hostname:
        return None
    return scheme, parsed.hostname.lower(), port


def same_origin(url: str, base: str) -> bool:
    origin = _origin(url)
    return origin is not None and origin == _origin(base)


def _auth_path(url: str) -> bool:
    path = urlparse(url).path
    return any(
        path.startswith(p) if p.endswith("/") else (path == p or path.startswith(p + "/"))
        for p in _AUTH_PATHS
    )


def credentials_allowed(url: str, base_url: str) -> bool:
    """True only for the Zulip server's own origin (scheme, host and port all
    equal base_url's, so https stays https) and only for upload/avatar/thumbnail
    paths."""
    return same_origin(url, base_url) and _auth_path(url)


def http_get(
    url, *, auth=None, auth_base=None, timeout, max_bytes,
    deadline=None, _get=None, max_redirects=3,
):
    """GET with a size cap and a total deadline. Returns (content_type, bytes).

    Redirects are followed by hand. Credentials are re-checked on every hop
    (credentials_allowed against auth_base) and dropped as soon as a hop fails;
    without auth_base no credentials are ever sent. The deadline (a
    time.monotonic() value) is checked before each hop. Raises HttpError.
    """
    if _get is None:
        import requests

        _get = requests.get
    if deadline is None:
        deadline = time.monotonic() + timeout * 2
    for _ in range(max_redirects + 1):
        if time.monotonic() > deadline:
            raise HttpError("too slow")
        if urlparse(url).scheme.lower() not in ("http", "https"):
            raise HttpError("unsupported scheme")
        if auth and auth_base and credentials_allowed(url, auth_base):
            send_auth = auth
        else:
            send_auth, auth = None, None  # once dropped, never sent again
        try:
            resp = _get(
                url, auth=send_auth, timeout=timeout, stream=True, allow_redirects=False
            )
        except Exception as error:
            raise HttpError(type(error).__name__) from None
        try:
            if resp.status_code in (301, 302, 303, 307, 308):
                location = resp.headers.get("location")
                if not location:
                    raise HttpError("redirect without location")
                url = urljoin(url, location)
                continue
            if resp.status_code != 200:
                raise HttpError(f"status {resp.status_code}")
            try:
                declared = int(resp.headers.get("content-length", 0))
            except ValueError:
                declared = 0
            if declared > max_bytes:
                raise HttpError("too large")
            body = bytearray()
            for chunk in resp.iter_content(8192):
                body += chunk
                if len(body) > max_bytes:
                    raise HttpError("too large")
                if time.monotonic() > deadline:
                    raise HttpError("too slow")
            ctype = resp.headers.get("content-type", "").split(";")[0].strip().lower()
            return ctype, bytes(body)
        except HttpError:
            raise
        except Exception as error:
            raise HttpError(type(error).__name__) from None
        finally:
            resp.close()
    raise HttpError("too many redirects")


def sips_convert(src, dst, max_px: int) -> bool:
    """Convert src to a PNG at most max_px on a side. argv only."""
    try:
        done = subprocess.run(
            ["sips", "-s", "format", "png", "-Z", str(max_px), str(src), "--out", str(dst)],
            capture_output=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return done.returncode == 0 and Path(dst).exists()


def _gravatar(url: str) -> bool:
    host = (urlparse(url).hostname or "").lower()
    return urlparse(url).scheme.lower() == "https" and (
        host == "gravatar.com" or host.endswith(".gravatar.com")
    )


def default_cache_dir() -> Path:
    return Path(os.path.expanduser("~")) / "Library/Caches/z-iris/media"


class ImageResolver:
    def __init__(
        self,
        registry: ClientRegistry,
        cache_dir: Path | None = None,
        http_get=http_get,
        convert=sips_convert,
        timeout: float = 4.0,
        max_image_bytes: int = 8 * 1024 * 1024,
        max_avatar_bytes: int = 1024 * 1024,
        cache_cap_bytes: int = 50 * 1024 * 1024,
        image_px: int = 512,
        avatar_px: int = 256,
        external_images=False,
        total_budget: float = 8.0,
        clock=time.monotonic,
    ) -> None:
        self.registry = registry
        self.cache_dir = Path(cache_dir) if cache_dir else default_cache_dir()
        self.http_get = http_get
        self.convert = convert
        self.timeout = timeout
        self.max_image_bytes = max_image_bytes
        self.max_avatar_bytes = max_avatar_bytes
        self.cache_cap_bytes = cache_cap_bytes
        self.image_px = image_px
        self.avatar_px = avatar_px
        self._external_images = external_images
        self.total_budget = total_budget
        self.clock = clock
        self._lock = threading.Lock()

    @property
    def external_images(self) -> bool:
        flag = self._external_images
        return bool(flag() if callable(flag) else flag)

    def image_for(self, message) -> Path | None:
        try:
            client = self.registry.get(message.server)
            deadline = self.clock() + self.total_budget
            for url in extract_image_urls(message.content)[:1]:
                path = self._fetch(
                    message.server, client, url, self.max_image_bytes,
                    self.image_px, deadline,
                )
                if path:
                    return path
            if message.avatar_url and self.clock() < deadline:
                return self._fetch(
                    message.server, client, message.avatar_url,
                    self.max_avatar_bytes, self.avatar_px, deadline, avatar=True,
                )
        except Exception:
            pass
        return None

    # internals

    def _fetch(self, server, client, url, max_bytes, max_px, deadline, avatar=False) -> Path | None:
        try:
            base = getattr(client, "base_url", None) if client is not None else None
            if urlparse(url).scheme:
                absolute = url
            elif base:
                absolute = urljoin(base, url)
            else:
                return None  # relative, and no server to resolve it against
            if urlparse(absolute).scheme.lower() not in ("http", "https"):
                return None
            final = self.cache_dir / (
                hashlib.sha256(f"{server}\n{absolute}".encode()).hexdigest()[:32] + ".png"
            )
            if final.exists():
                os.utime(final)
                return final

            if self.clock() >= deadline:
                return None
            fetch_url, auth = absolute, None
            if base and credentials_allowed(absolute, base):
                fetch_url, auth = self._server_target(client, absolute)
            elif base and same_origin(absolute, base):
                if not avatar:
                    return None  # the server's own host, but not a media path
                # server avatars such as /avatar/<id> are public: no credentials
            elif not (self.external_images or (avatar and _gravatar(absolute))):
                return None  # other hosts would see this machine's address
            kwargs = {"deadline": deadline}
            if auth:
                kwargs["auth_base"] = base
            ctype, body = self.http_get(
                fetch_url, auth=auth, timeout=self.timeout, max_bytes=max_bytes, **kwargs
            )
            if not ctype.startswith("image/") or "svg" in ctype:
                return None
            return self._store(body, final, max_px)
        except Exception:
            return None

    def _server_target(self, client, absolute):
        """(url, auth) for a URL on the Zulip server. Credentials leave the client
        object only here, for this host."""
        parsed = urlparse(absolute)
        prefix = "/user_uploads/"
        getter = getattr(client, "get_file_temporary_url", None)
        if getter and parsed.path.startswith(prefix) and not parsed.query:
            try:
                reply = getter(parsed.path[len(prefix):])
                if reply.get("result") == "success" and reply.get("url"):
                    return urljoin(absolute, reply["url"]), None
            except Exception:
                pass
        email, key = getattr(client, "email", None), getattr(client, "api_key", None)
        return absolute, ((email, key) if email and key else None)

    def _store(self, body: bytes, final: Path, max_px: int) -> Path | None:
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        fd, raw = tempfile.mkstemp(dir=self.cache_dir, suffix=".raw")
        out = Path(raw).with_suffix(".tmp.png")
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(body)
            if not self.convert(raw, out, max_px) or not out.exists():
                return None
            os.replace(out, final)
        finally:
            for leftover in (Path(raw), out):
                leftover.unlink(missing_ok=True)
        self._prune(keep=final)
        return final

    def _prune(self, keep: Path) -> None:
        with self._lock:
            files = []
            for f in self.cache_dir.glob("*.png"):
                try:
                    st = f.stat()
                except OSError:
                    continue
                files.append((st.st_mtime, f, st.st_size))
            total = sum(size for _, _, size in files)
            recent = time.time() - 60  # may be in use by a notification right now
            for mtime, f, size in sorted(files, key=lambda t: t[0]):
                if total <= self.cache_cap_bytes:
                    break
                if f == keep or mtime > recent:
                    continue
                f.unlink(missing_ok=True)
                total -= size
