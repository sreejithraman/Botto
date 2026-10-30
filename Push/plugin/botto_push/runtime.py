from __future__ import annotations

import logging
import os
from pathlib import Path
import threading

from .contracts import PushError, identity
from .service import PushService
from .storage import Storage

logger = logging.getLogger(__name__)


def data_directory():
    # Resolve inside the active Hermes profile on every entry, including HTTP.
    from plugins.plugin_storage import plugin_data_dir
    return plugin_data_dir("botto-push")


def active_profile(directory):
    try:
        from hermes_cli.profiles import get_active_profile_name
        active_directory = data_directory()
    except ImportError:
        return None
    if Path(active_directory).resolve() != directory.resolve():
        return None
    return identity(get_active_profile_name())


def configured_service(directory=None, *, profile=None, origin=None):
    directory = Path(directory) if directory is not None else data_directory()
    current = active_profile(directory)
    if profile is not None and current is not None and profile != current:
        raise PushError(409, "The requested profile does not match this active Hermes context.")
    if profile is None and current is None and not (directory / "push.sqlite3").exists():
        raise PushError(409, "Run in the intended Hermes profile, or specify its identity with --profile and --data-dir.")
    storage = Storage(directory)
    with storage.transaction() as db:
        values = dict(db.execute("SELECT key,value FROM metadata WHERE key IN ('profile','relay_url')"))
    profile = profile or current or values.get("profile")
    if profile is None:
        raise PushError(409, "Notification storage has no authenticated Hermes profile owner.")
    profile = identity(profile)
    selected = origin or os.environ.get("BOTTO_PUSH_RELAY_URL") or values.get("relay_url")
    service = PushService(directory, profile, selected)
    if selected:
        with service.storage.transaction() as db:
            db.execute("INSERT OR REPLACE INTO metadata VALUES ('relay_url', ?)", (service.origin,))
    return service


class Runtime:
    def __init__(self, service, contract_version, title_provider=None):
        self.service = service
        self.version = contract_version
        self.title_provider = title_provider
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self._run, name="botto-push-outbox", daemon=True)

    def start(self):
        self.service.mark_runtime(self.version)
        self.thread.start()

    def observe(self, *, event, **_):
        if self.stopped.is_set() or self.version != 1:
            return
        try:
            self.service.mark_runtime(self.version)
            if self.title_provider is not None:
                event = {**event, "title": self.title_provider()}
            self.service.produce(event)
        except PushError as error:
            logger.warning("Botto notification event was not accepted (status %s)", error.status)
        except Exception:
            # Do not include event content, tokens, or exception arguments in logs.
            logger.warning("Botto notification event could not be persisted")

    def _run(self):
        recovering = False
        try:
            while not self.stopped.is_set():
                try:
                    self.service.mark_runtime(self.version)
                    self.service.flush(limit=1, wait_for_dispatch=False)
                    recovering = False
                except Exception:
                    if not recovering:
                        logger.warning("Botto notification outbox needs recovery")
                    recovering = True
                self.stopped.wait(1)
        finally:
            self.service.mark_runtime(0)

    def close(self):
        self.stopped.set()
        self.thread.join(timeout=11)
        self.service.mark_runtime(0)


def register(ctx, *, directory=None):
    version = getattr(ctx, "native_session_events_version", 0)
    version = version if type(version) is int and version == 1 else 0
    selected = ctx.get_config("relay_url", None)
    service = configured_service(directory, profile=ctx.profile_name, origin=selected)
    from hermes_constants import get_hermes_home
    from hermes_cli.profiles import read_profile_meta
    profile_home = Path(get_hermes_home())
    profile_label = ctx.profile_name

    def title():
        try:
            metadata = read_profile_meta(profile_home)
            value = metadata.get("bot_title") or metadata.get("display_name") or profile_label
            return value if isinstance(value, str) else profile_label
        except Exception:
            return profile_label

    runtime = Runtime(service, version, title)
    if version:
        ctx.register_hook("on_native_session_event", runtime.observe)
    ctx.on_unload(runtime.close)
    runtime.start()
    return runtime

