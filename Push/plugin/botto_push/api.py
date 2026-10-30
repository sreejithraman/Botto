from __future__ import annotations

import json

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

from .contracts import PushError


def _object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON field")
        result[key] = value
    return result


async def _body(request):
    if request.headers.get("content-type", "").split(";", 1)[0].strip() != "application/json":
        raise HTTPException(400, "Use an application/json request.", headers={"Cache-Control": "no-store"})
    chunks = bytearray()
    async for chunk in request.stream():
        chunks.extend(chunk)
        if len(chunks) > 32768:
            raise HTTPException(413, "Notification request is too large.", headers={"Cache-Control": "no-store"})
    try:
        def invalid_constant(_):
            raise ValueError("Non-finite JSON number")
        return json.loads(chunks, object_pairs_hook=_object, parse_constant=invalid_constant)
    except (ValueError, UnicodeError):
        raise HTTPException(400, "Invalid notification JSON.", headers={"Cache-Control": "no-store"}) from None


def create_router(service_factory):
    """Hermes mounts this router behind its normal owner/profile authorization."""
    router = APIRouter()

    async def execute(request, operation, identifier=None):
        data = await _body(request)
        try:
            service = service_factory()
            method = getattr(service, operation)
            result = await run_in_threadpool(method, identifier, data) if identifier is not None else await run_in_threadpool(method, data)
            return JSONResponse(result, headers={"Cache-Control": "no-store"})
        except PushError as error:
            raise HTTPException(error.status, error.message, headers={"Cache-Control": "no-store"}) from None

    @router.get("/status")
    def status():
        try:
            return JSONResponse(service_factory().status(), headers={"Cache-Control": "no-store"})
        except PushError as error:
            raise HTTPException(error.status, error.message, headers={"Cache-Control": "no-store"}) from None

    @router.post("/devices")
    async def enroll(request: Request):
        return await execute(request, "enroll")

    @router.post("/devices/{device_id}/remove")
    async def remove(device_id: str, request: Request):
        return await execute(request, "remove", device_id)

    @router.post("/devices/{device_id}/test")
    async def test(device_id: str, request: Request):
        return await execute(request, "test", device_id)

    return router

