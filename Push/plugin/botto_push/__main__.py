from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import uuid

from .contracts import PushError, relay_url
from .runtime import configured_service


def main(argv=None):
    parser = argparse.ArgumentParser(description="Manage this Hermes profile's Botto notification pairings.")
    parser.add_argument("--data-dir", type=Path, help="Explicit owner-controlled storage, for recovery or testing")
    parser.add_argument("--profile", help="Expected profile identity; this flag does not switch the Hermes profile context")
    sub = parser.add_subparsers(dest="command", required=True)
    configure = sub.add_parser("configure", help="Set the public HTTPS relay origin")
    configure.add_argument("relay_url")
    sub.add_parser("status")
    sub.add_parser("devices")
    removal = sub.add_parser("remove", help="Remove one device without changing other pairings")
    removal.add_argument("device_id")
    sub.add_parser("drain", help="Attempt a bounded drain of pending relay operations")
    args = parser.parse_args(argv)
    try:
        origin = relay_url(args.relay_url) if args.command == "configure" else None
        service = configured_service(args.data_dir, profile=args.profile, origin=origin)
        if args.command == "configure":
            result = {"status": "configured", "relay_url": service.origin,
                      "note": "Reload the plugin to apply configuration to the native producer."}
        elif args.command == "remove":
            result = service.remove(args.device_id, {"v": 1, "operation_id": str(uuid.uuid4())})
        elif args.command == "drain":
            service.flush()
            result = service.status()
        else:
            result = service.status()
            if args.command == "devices":
                result = result["devices"]
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return 0
    except PushError as error:
        print(error.message, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
