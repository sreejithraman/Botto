"""One private HTTP request, isolated so its owner can enforce a total deadline."""

import json
import os
import signal
import ssl
import sys
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, HTTPSHandler, Request, build_opener


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def perform(command):
    try:
        context = ssl.create_default_context(cafile=os.environ.get("SSL_CERT_FILE") or None)
        opener = build_opener(NoRedirect, HTTPSHandler(context=context))
        request = Request(command["url"], command["body"].encode(), method=command["method"],
                          headers={"Content-Type": "application/json", "Authorization": "Bearer " + command["token"]})
        with opener.open(request, timeout=command["timeout"]) as response:
            raw = response.read(32_769)
            if len(raw) > 32_768 or response.url != command["url"]:
                return {"retryable": False}
            result = json.loads(raw)
            if not isinstance(result, dict) or result.get("v") != 1 or not isinstance(result.get("status"), str):
                return {"retryable": False}
            return {"result": result}
    except HTTPError as error:
        return {"retryable": error.code in {408, 425, 429, 500, 502, 503, 504}}
    except (URLError, OSError, TimeoutError, ValueError):
        return {"retryable": True}


if __name__ == "__main__":
    command = json.load(sys.stdin)
    # Bound orphaned requests too if the host exits before it can reap us.
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.setitimer(signal.ITIMER_REAL, command["timeout"])
    json.dump(perform(command), sys.stdout, separators=(",", ":"))
