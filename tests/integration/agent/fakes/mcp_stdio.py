"""A minimal MCP server over stdio (JSON-RPC 2.0, one message per line).

Enough of the protocol for Claude Code to list and call tools: initialize, ping,
tools/list, tools/call. No SDK, so the fakes pin nothing but Python.
"""
import json
import sys
import traceback

PROTOCOL = "2025-06-18"


class Server:
    def __init__(self, name, version="1.0.0", instructions=None):
        self.name, self.version, self.instructions = name, version, instructions
        self.tools = {}

    def tool(self, name, description, schema):
        def register(fn):
            self.tools[name] = {"fn": fn, "description": description, "schema": schema}
            return fn
        return register

    def _reply(self, id_, result=None, error=None):
        msg = {"jsonrpc": "2.0", "id": id_}
        msg.update({"error": error} if error else {"result": result})
        sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
        sys.stdout.flush()

    def _call(self, name, args):
        tool = self.tools.get(name)
        if not tool:
            return {"content": [{"type": "text", "text": f"Unknown tool: {name}"}], "isError": True}
        try:
            out = tool["fn"](**(args or {}))
        except ToolError as e:
            return {"content": [{"type": "text", "text": str(e)}], "isError": True}
        except TypeError as e:
            return {"content": [{"type": "text", "text": f"Invalid arguments: {e}"}], "isError": True}
        except Exception:
            return {"content": [{"type": "text", "text": traceback.format_exc(limit=2)}], "isError": True}
        text = out if isinstance(out, str) else json.dumps(out, ensure_ascii=False, default=str)
        return {"content": [{"type": "text", "text": text}]}

    def serve(self):
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            method, id_ = msg.get("method"), msg.get("id")
            if id_ is None:                      # a notification
                continue
            if method == "initialize":
                result = {"protocolVersion": msg.get("params", {}).get("protocolVersion", PROTOCOL),
                          "capabilities": {"tools": {"listChanged": False}},
                          "serverInfo": {"name": self.name, "version": self.version}}
                if self.instructions:
                    result["instructions"] = self.instructions
                self._reply(id_, result)
            elif method == "ping":
                self._reply(id_, {})
            elif method == "tools/list":
                self._reply(id_, {"tools": [{"name": n, "description": t["description"], "inputSchema": t["schema"]}
                                            for n, t in self.tools.items()]})
            elif method == "tools/call":
                p = msg.get("params", {})
                self._reply(id_, self._call(p.get("name"), p.get("arguments")))
            else:
                self._reply(id_, error={"code": -32601, "message": f"Method not found: {method}"})


class ToolError(Exception):
    """A failure the real connector would report to the model as a tool error."""
