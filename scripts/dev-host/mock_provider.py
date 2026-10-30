"""Deterministic loopback OpenAI peer. Only this provider wire is simulated."""

from http.server import BaseHTTPRequestHandler
import json

MODEL = "botto-local-deterministic"
COMMAND = 'python3 -c "print(\'BOTTO_APPROVAL_OK\')"'


def reply(body):
    messages = body.get("messages") or []
    last = messages[-1] if messages else {}
    user = next((str(m.get("content", "")) for m in reversed(messages)
                 if m.get("role") == "user"), "")
    tool = next((m for m in reversed(messages) if m.get("role") == "tool"), None)
    if last.get("role") == "tool" and tool:
        text = "BOTTO_TOOL_DONE " + str(tool.get("content", ""))
        return {"role": "assistant", "content": text}, "stop"
    if "BOTTO_QUESTION" in user and any(
            tool.get("function", {}).get("name") == "clarify"
            for tool in body.get("tools", [])):
        call = {"id": "call_botto_question_" + str(len(messages)), "type": "function", "function": {
            "name": "clarify", "arguments": json.dumps({"questions": [
                {"question": "What should the note say?"}]})}}
        return {"role": "assistant", "content": "I need the note text.", "tool_calls": [call]}, "tool_calls"
    if "BOTTO_APPROVAL" in user and body.get("tools"):
        call = {"id": "call_botto_" + str(len(messages)), "type": "function", "function": {
            "name": "terminal", "arguments": json.dumps({"command": COMMAND})}}
        return {"role": "assistant", "content": "Running the disposable check.", "tool_calls": [call]}, "tool_calls"
    return {"role": "assistant", "content": "BOTTO_LOCAL_ACK " + user[-200:]}, "stop"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.rstrip("/") == "/v1/models":
            return self.send_json(200, {"object": "list", "data": [{"id": MODEL, "object": "model", "owned_by": "botto"}]})
        self.send_json(404, {"error": {"message": "Unknown local mock route"}})

    def do_POST(self):
        if self.path.rstrip("/") != "/v1/chat/completions":
            return self.send_json(404, {"error": {"message": "Unknown local mock route"}})
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        message, finish = reply(body)
        self.server.stats["requests"] += 1
        self.server.stats["streaming_requests"] += bool(body.get("stream"))
        base = {"id": "chatcmpl-botto-local", "model": MODEL, "created": 1}
        usage = {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
        if not body.get("stream"):
            return self.send_json(200, {**base, "object": "chat.completion", "usage": usage,
                "choices": [{"index": 0, "message": message, "finish_reason": finish}]})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        deltas = [{"role": "assistant"}]
        text = message["content"]
        # Multiple chunks exercise the actual upstream stream parser.
        deltas.extend({"content": text[i:i + 12]} for i in range(0, len(text), 12))
        for index, call in enumerate(message.get("tool_calls", [])):
            deltas.append({"tool_calls": [{"index": index, **call}]})
        for delta in deltas:
            self.chunk({**base, "object": "chat.completion.chunk", "choices": [
                {"index": 0, "delta": delta, "finish_reason": None}]})
        self.chunk({**base, "object": "chat.completion.chunk", "choices": [
            {"index": 0, "delta": {}, "finish_reason": finish}]})
        self.chunk({**base, "object": "chat.completion.chunk", "choices": [], "usage": usage})
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self.close_connection = True

    def chunk(self, body):
        self.wfile.write(("data: " + json.dumps(body) + "\n\n").encode())
        self.wfile.flush()
