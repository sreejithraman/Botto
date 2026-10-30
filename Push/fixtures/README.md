# Public notification fixtures

These JSON files and `plugin/tests/fixtures/encrypted-preview.json` contain
synthetic routing identities, fixed test keys, and fixed test nonces. They do
not contain a real installation capability, APNs token, or private chat.

The AES-256-GCM boxes use Python `cryptography` AESGCM and Botto v1 additional
data. `sealed` is base64 of the 12-byte nonce followed by ciphertext and tag.
The JSON fixture plaintext uses UTF-8, compact separators, and sorted keys.
The fixed nonce is `bytes(range(12))`; never reuse a nonce with a real key.

Regenerate a JSON fixture's box from its existing public fields with:

```python
import base64
import json
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

key = base64.b64decode(fixture["key_base64"])
nonce = bytes(range(12))
clear = json.dumps(
    fixture["plaintext"], sort_keys=True, separators=(",", ":"), ensure_ascii=False
).encode()
aad = fixture["aad"].encode()
fixture["envelope"]["sealed"] = base64.b64encode(
    nonce + AESGCM(key).encrypt(nonce, clear, aad)
).decode()
```

`Tests/BottoCoreTests/PushPreviewTests.swift` carries a separate Python-produced
box using key `bytes(range(32))`, the same fixed nonce, and these exact plaintext
bytes:

```json
{"v":1,"title":"Milo","body":"Ready","profile_id":"bot","root_id":"root","stored_id":"stored"}
```

Its additional data is `botto-push:v1`, 64 `a` characters, 32 `b` characters,
`1`, and 64 `c` characters, joined by newlines with no trailing newline.
Swift decrypts this box independently of the Python producer.

The boundary fixture holds a 2,598-byte plaintext, 2,626-byte combined box,
and 3,504-character base64 string. The full Botto APNs payload is 3,970 bytes.
Python tests check production encryption and fallback; Swift checks decryption
and exact long destinations; relay tests check the complete provider payload.
This demonstrates interoperability and size limits, not real Apple delivery.
