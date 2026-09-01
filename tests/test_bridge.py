import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from discord_bridge import _user_voice_args, _voice_entry_fields


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


if __name__ == "__main__":
    unittest.main()
