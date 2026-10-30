"""Ordinary upstream gateway; select its otherwise ephemeral native API port."""

import functools
import os

from gateway import run_api

# Upstream start_gateway_runtime_api calls this without host/port arguments.
# This changes listener placement only. No auth/session/model logic is patched.
run_api.start_gateway_api = functools.partial(
    run_api.start_gateway_api, host="127.0.0.1", port=int(os.environ["BOTTO_HOST_PORT"]))

from gateway.run import main

if __name__ == "__main__":
    main()
