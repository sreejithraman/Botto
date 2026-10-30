/// Versioned instructions shared with the user's existing Hermes. Contains no connection secrets.
enum HermesSetupPrompt {
    static let version = 2

    static let text = """
    Help me connect Botto, an iPhone/iPad app, to this existing Hermes installation. These are Botto setup instructions v2.

    Work on the host where my Hermes and bots already run. If you cannot access it, explain what access is missing instead of setting up another machine.

    1. Inspect first. Find the installed Hermes version, active home/profile, running gateway, native API listener, authentication, service manager, and existing HTTPS or private-network routes. Botto requires Hermes 0.21.5 or newer. For an older release or a missing/malformed status version, return Blocked and explain the required update without upgrading. A source build reporting the literal version unknown still needs all auth/protocol checks; report its version as unverified. Discover the actual address and port using the installed version's supported inspection commands. Reuse the gateway's native listener and session authority where available; standalone dashboard/serve may not expose the running gateway's bots. Preserve my install_id, conversations, profiles, model settings, config, credentials, and unrelated routes. Avoid a second competing listener, an upgrade, or a reinstall.

    2. Prepare the connection. Botto uses the official native Hermes HTTP API and /api/ws. A separate WebUI, mobile adapter, or relay is unnecessary. Prefer an existing authenticated HTTPS origin reachable from my iPhone, including through my private network or VPN. Keep the existing sign-in provider. If host changes are needed, explain the exact changes and wait for my agreement before applying them, including software installation (except the temporary QR-only environment in step 4), public exposure, authentication changes, binding beyond loopback, or service restarts. Apply agreed changes through the existing service manager and preserve other configuration. Check dashboard.public_url against the phone-facing origin before proposing any correction.

    3. Verify honestly. Check GET /api/status locally and through the phone-facing HTTPS origin. Confirm authentication is required. Botto needs the basic provider for username/password sign-in, or the native_pkce auth flow with an interactive provider for browser sign-in. Report the advertised methods and which supported path I can use. If neither is available, return Blocked, preserve existing authentication, and explain the next step before proposing changes. An HTML proxy-login page is not an API success. Check /api/ws upgrade support and required proxy headers. If an existing authorized session permits a read-only WebSocket check, verify gateway.ready; otherwise mark it pending Botto sign-in. Keep credentials private. A host-side check does not prove reachability from my phone.

    4. Create the connection QR. Once the origin is ready, generate a real, scannable QR image encoding botto://hermes/connect?url=<percent-encoded HTTPS origin>. QR delivery is part of completing setup. Use an available local encoder or runtime library. If none is installed, you may create a temporary isolated environment and install a QR-only dependency there without another confirmation; keep Hermes dependencies and system packages unchanged. If one method fails, try another suitable local method. A missing preinstalled QR command is a reason to use a fallback, not to stop. Use a QR encoder, not a drawn approximation or an online QR service. If a decoder is available, decode the saved image and compare its payload with the exact Botto link; otherwise report that decoding was not checked. Attach the actual PNG image using this chat's file/image tools. If attachment is unavailable, provide an accessible file or download link supported by this chat. A local path alone is not delivery unless I can access it. If generation or delivery is genuinely blocked, state the methods attempted, their exact failures, and the next step; still provide the origin and Botto link.

    5. Send back a short connection handoff:
    - Ready for Botto sign-in, or Blocked with the exact next step.
    - The QR image first when the origin is ready, or the concrete QR generation/delivery blocker.
    - The plain HTTPS server origin on its own line, with its actual port when needed. No /api, other path, query, fragment, or embedded credentials.
    - An Open Botto link using the same payload. If this chat blocks custom-scheme links, include the literal link as code and keep the QR and plain-origin fallback available.
    - Only the phone network/VPN steps and sign-in method I need next. Put check results and any remaining limitations after these actions.

    Keep passwords, tokens, service credentials, WebSocket tickets, and auth codes out of replies, logs, links, and QR codes. I will enter credentials or use browser sign-in in Botto. Tell me to open the link or paste the origin into Botto, review the destination, sign in, and open a bot/send a message. Call the connection verified only after that phone check succeeds.
    """
}
