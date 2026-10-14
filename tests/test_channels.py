from pathlib import Path

from z_iris.channels import ChannelSource
from z_iris.config import ServerConfig


class Client:
    calls = 0

    def __init__(self, names):
        self.names = names

    def get_subscriptions(self):
        Client.calls += 1
        return {"result": "success",
                "subscriptions": [{"name": n, "stream_id": i} for i, n in enumerate(self.names)]}


def servers(*names):
    return [ServerConfig(n, Path("/x")) for n in names]


def test_lists_sorted_subscribed_channels_per_server_and_all():
    clients = {"a": Client(["zeta", "Alpha"]), "b": Client(["alpha2", "zeta"])}
    src = ChannelSource(lambda rc: clients[rc.name])
    result = src.channels([ServerConfig("a", Path("a")), ServerConfig("b", Path("b"))])
    assert result["servers"] == [
        {"name": "a", "channels": ["Alpha", "zeta"]},
        {"name": "b", "channels": ["alpha2", "zeta"]},
    ]
    assert result["all"] == ["Alpha", "alpha2", "zeta"]


def test_results_are_cached_and_errors_are_reported_per_server():
    Client.calls = 0
    src = ChannelSource(lambda _rc: Client(["x"]), now=lambda: 0.0)
    src.channels(servers("a"))
    src.channels(servers("a"))
    assert Client.calls == 1

    def broken(_rc):
        raise OSError("offline")

    result = ChannelSource(broken).channels(servers("a"))
    assert "offline" in result["servers"][0]["error"]
    assert result["servers"][0]["channels"] == [] and result["all"] == []
