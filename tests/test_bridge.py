import asyncio
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from discord_bridge import DiscordBridge, _user_voice_args, _voice_entry_fields


class VoiceEntryFieldsTests(unittest.TestCase):
    def test_extracts_local_volume_mute_and_suppress(self):
        vs = {
            "nick": "n",
            "mute": True,
            "volume": 150,
            "voice_state": {
                "mute": False,
                "self_mute": True,
                "deaf": False,
                "self_deaf": False,
                "suppress": True,
            },
            "user": {"id": "1", "username": "u", "avatar": "a"},
        }
        e = _voice_entry_fields(vs)
        self.assertEqual(e["volume"], 150)
        self.assertEqual(e["local_mute"], True)
        self.assertEqual(e["suppress"], True)
        self.assertEqual(e["self_mute"], True)
        self.assertEqual(e["mute"], False)
        self.assertEqual(e["id"], "1")
        self.assertEqual(e["nick"], "n")

    def test_defaults_when_fields_missing(self):
        e = _voice_entry_fields({"user": {"id": "2"}})
        self.assertEqual(e["volume"], 100)
        self.assertEqual(e["local_mute"], False)
        self.assertEqual(e["suppress"], False)
        self.assertEqual(e["nick"], "")

    def test_nick_falls_back_to_username(self):
        e = _voice_entry_fields({"user": {"id": "3", "username": "bob"}})
        self.assertEqual(e["nick"], "bob")


class UserVoiceArgsTests(unittest.TestCase):
    def test_clamps_volume_above_max(self):
        self.assertEqual(_user_voice_args({"user_id": "1", "volume": 250})["volume"], 200)

    def test_clamps_volume_below_zero(self):
        self.assertEqual(_user_voice_args({"user_id": "1", "volume": -5})["volume"], 0)

    def test_passes_through_in_range_volume(self):
        self.assertEqual(_user_voice_args({"user_id": "1", "volume": 150})["volume"], 150)

    def test_mute_coerced_to_bool(self):
        self.assertEqual(_user_voice_args({"user_id": "1", "mute": 1})["mute"], True)

    def test_returns_none_without_user_id(self):
        self.assertIsNone(_user_voice_args({"volume": 100}))

    def test_only_includes_provided_fields(self):
        self.assertEqual(_user_voice_args({"user_id": "1"}), {"user_id": "1"})


class FakeIPC:
    """Stand-in for DiscordIPC with a handshake slow enough to interleave."""

    def __init__(self, eof: bool = False) -> None:
        self.is_connected = False
        self.eof = eof
        self.handshakes = 0
        self.authenticates = 0
        self._nonce = 0

    @property
    def connected(self) -> bool:
        return self.is_connected

    async def connect(self) -> bool:
        self.is_connected = True
        return True

    async def handshake(self, client_id: str) -> dict:
        self.handshakes += 1
        await asyncio.sleep(0.01)
        return {"evt": "READY"}

    async def authenticate(self, token: str) -> str:
        self.authenticates += 1
        self._nonce += 1
        return str(self._nonce)

    async def recv_frame(self):
        if self.eof:
            raise asyncio.IncompleteReadError(b"", 8)
        await asyncio.sleep(3600)

    def close(self) -> None:
        self.is_connected = False


def _bridge(fake: FakeIPC) -> DiscordBridge:
    bridge = DiscordBridge("/nonexistent/dms-discord-voice-test.sock")
    bridge.discord = fake
    bridge.tokens.load = lambda: "token"
    bridge.tokens.consented = True
    return bridge


class ConnectFlowTests(unittest.IsolatedAsyncioTestCase):
    async def test_concurrent_connects_authenticate_once(self):
        fake = FakeIPC()
        bridge = _bridge(fake)
        try:
            await asyncio.gather(bridge._do_connect_flow(), bridge._do_connect_flow())
            self.assertEqual(fake.handshakes, 1)
            self.assertEqual(fake.authenticates, 1)
        finally:
            if bridge._discord_task:
                bridge._discord_task.cancel()

    async def test_disconnect_clears_pending(self):
        fake = FakeIPC(eof=True)
        bridge = _bridge(fake)
        fake.is_connected = True
        bridge._pending["1"] = "AUTHENTICATE"
        await bridge._discord_read_loop()
        self.assertEqual(bridge._pending, {})
        self.assertFalse(bridge.authenticated)


if __name__ == "__main__":
    unittest.main()
