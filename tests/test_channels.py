from pathlib import Path

from z_iris.channels import ChannelSource
from z_iris.config import ServerConfig


class Client:
    calls = 0

    def __init__(self, traffic):
        self.traffic = traffic  # name -> weekly messages, or None for a new channel
        self.kwargs = None

    def get_streams(self, **kwargs):
        Client.calls += 1
        self.kwargs = kwargs
        return {"result": "success", "streams": [
            {"name": n, "stream_id": i, "stream_weekly_traffic": t}
            for i, (n, t) in enumerate(self.traffic.items())]}


def servers(*names):
    return [ServerConfig(n, Path("/x")) for n in names]


def test_every_channel_busiest_first_per_server_and_all():
    clients = {"a": Client({"quiet": 1, "Busy": 500, "new": None, "mid": 40}),
               "b": Client({"quiet": 900, "other": 3})}
    src = ChannelSource(lambda rc: clients[rc.name])
    result = src.channels([ServerConfig("a", Path("a")), ServerConfig("b", Path("b"))])
    assert result["servers"] == [
        {"name": "a", "channels": ["Busy", "mid", "quiet", "new"]},
        {"name": "b", "channels": ["quiet", "other"]},
    ]
    # across servers a channel counts its busiest server
    assert result["all"] == ["quiet", "Busy", "mid", "other", "new"]
    assert clients["a"].kwargs["include_public"] is True  # not only subscriptions


def test_ties_sort_by_name():
    src = ChannelSource(lambda rc: Client({"b": 5, "A": 5, "c": 5}))
    assert src.channels(servers("a"))["all"] == ["A", "b", "c"]


def test_results_are_cached_and_errors_are_reported_per_server():
    Client.calls = 0
    src = ChannelSource(lambda _rc: Client({"x": 1}), now=lambda: 0.0)
    src.channels(servers("a"))
    src.channels(servers("a"))
    assert Client.calls == 1

    def broken(_rc):
        raise OSError("offline")

    result = ChannelSource(broken).channels(servers("a"))
    assert "offline" in result["servers"][0]["error"]
    assert result["servers"][0]["channels"] == [] and result["all"] == []
