"""Build zulip:// links that Zulip Desktop opens in the right chat."""

from __future__ import annotations

from urllib.parse import quote

from z_iris.message import Message


def encode_component(text: str) -> str:
    """Encode text the way Zulip does in narrow hashes.

    Zulip percent-encodes everything, then writes "." instead of "%", so a real
    "." must be encoded first.
    """
    return quote(text, safe="").replace(".", "%2E").replace("%", ".")


def narrow_url(message: Message) -> str:
    base = f"zulip://{message.host}/#narrow"
    if message.kind == "channel":
        channel = f"{message.channel_id}-{encode_component(message.channel_name or '')}"
        topic = encode_component(message.topic or "")
        return f"{base}/stream/{channel}/topic/{topic}/near/{message.id}"

    ids = ",".join(str(i) for i in message.dm_user_ids)
    suffix = "group" if len(message.dm_user_ids) > 1 else "pm"
    return f"{base}/dm/{ids}-{suffix}/near/{message.id}"
