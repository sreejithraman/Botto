---
status: accepted
---

# Isolate interactive assistant content

Botto renders assistant HTML in isolated, temporary WebKit environments with local
interactivity and no Hermes credentials, network access, or privileged native
actions. Generated output remains untrusted even when downloaded through an
authenticated chat, so loading a file grants it no additional rendering privileges.
This permits self-contained interactive visuals while keeping external resources
and host actions outside the preview; source remains available when rendering fails.

Formats, limits, and rendering behavior: [rich replies and files](../rich-content.md).
