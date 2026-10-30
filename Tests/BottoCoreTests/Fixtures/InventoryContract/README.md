These synthetic fixtures preserve the pinned host response shapes. Values are disposable.

- `authority.json`: Hermes Agent `4a0eaf7989b6804319ddb94fa5d96c5a716080a1`, `gateway/session_active_list.py` and `gateway/session_group_controls.py`. Each activity response belongs to the explicitly routed profile. `id` and `session_key` both identify the authority session.
- `sidecar.json`: Hermes Agent 0.21.5 `ca6782850432927f33df4775cb6dd45bb51460d2`, `tui_gateway/server.py` (`_session_live_item`) and `tui_gateway/methods_session.py` (`session.active_list`). One process-wide response; `id` is a runtime and `session_key` is a stored root or compression tip.
- Both omit profile, running and request fields on activity rows. Activity comes from `status`; canonical root/tip identity comes from roster `canonical_session`, as in Hermex `47809f2cd1f07bcbe592ee8960cf9c63e88b734c`, `Features/Bots/BotConnection.swift`.
- A canonical Bot Chat can have a continuation title. A separate ordinary chat waiting for input must not affect the bot status.
