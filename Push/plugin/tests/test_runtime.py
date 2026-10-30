from __future__ import annotations

from contextlib import contextmanager
from pathlib import Path
import sys
import tempfile
from types import ModuleType
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from botto_push.contracts import PushError
from botto_push.runtime import configured_service, register


@contextmanager
def hermes_profile(home, profile, data):
    """Fixture for Hermes's supported context-scoped profile/storage facades."""
    constants = ModuleType("hermes_constants")
    constants.get_hermes_home = lambda: home
    profiles = ModuleType("hermes_cli.profiles")
    profiles.get_active_profile_name = lambda: profile
    profiles.read_profile_meta = lambda _: {"bot_title": "Bot " + profile}
    storage = ModuleType("plugins.plugin_storage")
    storage.plugin_data_dir = lambda name: data
    plugins = ModuleType("plugins")
    plugins.plugin_storage = storage
    cli = ModuleType("hermes_cli")
    cli.profiles = profiles
    with patch.dict(sys.modules, {"hermes_constants": constants, "hermes_cli": cli,
                                 "hermes_cli.profiles": profiles, "plugins": plugins,
                                 "plugins.plugin_storage": storage}):
        yield


class Context:
    native_session_events_version = 1

    def __init__(self, profile):
        self.profile_name = profile
        self.hooks = {}
        self.cleanup = None

    def get_config(self, _, default):
        return "https://push.example"

    def register_hook(self, name, callback):
        self.hooks[name] = callback

    def on_unload(self, callback):
        self.cleanup = callback


class RuntimeTests(unittest.TestCase):
    def test_status_before_lifecycle_register_preserves_default_and_named_owners(self):
        with tempfile.TemporaryDirectory() as directory:
            for profile in ("default", "named-bot"):
                home = Path(directory) / profile
                data = home / "plugin-data" / "botto-push"
                with self.subTest(profile=profile), hermes_profile(home, profile, data):
                    service = configured_service(origin="https://push.example")
                    self.assertEqual(service.profile, profile)
                    self.assertFalse(service.status()["supported"])
                    context = Context(profile)
                    runtime = register(context)
                    try:
                        self.assertIn("on_native_session_event", context.hooks)
                        self.assertTrue(configured_service().status()["supported"])
                    finally:
                        context.cleanup()
                    self.assertFalse(configured_service().status()["supported"])

    def test_genuine_profile_mismatch_remains_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory) / "owner"
            data = home / "plugin-data" / "botto-push"
            with hermes_profile(home, "owner", data):
                configured_service(origin="https://push.example")
            with hermes_profile(home, "other", data):
                with self.assertRaises(PushError) as context:
                    configured_service()
                self.assertEqual(context.exception.status, 409)
            with hermes_profile(home, "owner", data):
                self.assertEqual(configured_service().profile, "owner")

    def test_unknown_fresh_profile_does_not_persist_placeholder_owner(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory) / "not-created"
            with patch.dict(sys.modules, {"hermes_cli.profiles": None, "plugins.plugin_storage": None}):
                with self.assertRaises(PushError) as context:
                    configured_service(data)
            self.assertEqual(context.exception.status, 409)
            self.assertFalse(data.exists())
            service = configured_service(data, profile="actual-profile", origin="https://push.example")
            self.assertEqual(service.profile, "actual-profile")


if __name__ == "__main__":
    unittest.main()
