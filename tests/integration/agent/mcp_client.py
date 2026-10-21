"""The client side of MCP over stdio: what Claude Code does with the connectors.

Spawns each server from an mcp.json-style config, initializes it, and calls tools by
their connector names (`Gmail`, `Google_Drive`, `Supabase`, …). A tool result flagged
isError raises ToolFailure with the text the model would have read.
"""
import json
import subprocess


class ToolFailure(Exception):
    pass


class McpClient:
    def __init__(self, config):
        self.config = config["mcpServers"]
        self.procs = {}
        self.next_id = 0

    def _proc(self, server):
        if server not in self.procs:
            spec = self.config[server]
            p = subprocess.Popen([spec["command"], *spec["args"]], env=spec.get("env"), text=True,
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=1)
            self.procs[server] = p
            self._rpc(server, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                             "clientInfo": {"name": "lifeos-scripted-agent", "version": "1"}})
            p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        return self.procs[server]

    def _rpc(self, server, method, params):
        p = self.procs[server]
        self.next_id += 1
        p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params}) + "\n")
        p.stdin.flush()
        msg = json.loads(p.stdout.readline())
        if "error" in msg:
            raise ToolFailure(f"{server} {method}: {msg['error']}")
        return msg["result"]

    def tools(self, server):
        self._proc(server)
        return {t["name"] for t in self._rpc(server, "tools/list", {})["tools"]}

    def call(self, server, tool, **args):
        self._proc(server)
        res = self._rpc(server, "tools/call", {"name": tool, "arguments": args})
        text = "".join(c.get("text", "") for c in res.get("content", []))
        if res.get("isError"):
            raise ToolFailure(text)
        return text

    def close(self):
        for p in self.procs.values():
            p.stdin.close()
            p.wait(timeout=10)
