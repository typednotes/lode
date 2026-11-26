#!/usr/bin/env python3
"""Stdio fixture that checks the exact MCP lifecycle before calling one tool."""

import json
import os
import sys


def receive():
    message = json.loads(sys.stdin.readline())
    assert message["jsonrpc"] == "2.0"
    return message


def send(id, result):
    print(json.dumps({"jsonrpc": "2.0", "id": id, "result": result}), flush=True)


assert "LODE_MODEL_API_KEY" not in os.environ and "LODE_SECRETS_TOKEN" not in os.environ
init = receive()
assert init["method"] == "initialize" and init["params"]["protocolVersion"] == "2025-11-25"
send(init["id"], {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}},
                  "serverInfo": {"name": "fixture", "version": "1"}})
notification = receive()
assert notification == {"jsonrpc": "2.0", "method": "notifications/initialized"}
call = receive()
assert call["method"] == "tools/call" and call["params"]["name"] == "fixture_echo"
send(call["id"], {"content": [], "structuredContent": {"echo": call["params"]["arguments"]["value"]}})
sys.stdin.read()
