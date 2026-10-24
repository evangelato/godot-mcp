#!/usr/bin/env python3
"""godot-mcp — an MCP server that lets a Claude session play any Godot 4 game.

Zero dependencies (Python stdlib only) and zero files installed into the game
project: the in-game half (bridge_main.gd, next to this file) is injected at
launch via Godot's `-s` script flag.

Register per game project in its .mcp.json:

    {
      "mcpServers": {
        "godot": {
          "command": "uvx",
          "args": ["--from", "git+https://github.com/evangelato/godot-mcp",
                   "godot-mcp"],
          "env": {
            "GODOT_MCP_NOTES": "This game's controls: ... (optional)"
          }
        }
      }
    }

Configuration (all optional, via env or argv[1] for the project dir):
    GODOT_MCP_PROJECT  game project dir (default: cwd, which Claude Code sets
                       to the workspace root)
    GODOT_BIN          Godot binary (default: `godot` on PATH, else the macOS
                       /Applications/Godot.app location)
    GODOT_MCP_PORT     bridge TCP port (default 7777; set per-project if you
                       run several games at once)
    GODOT_MCP_SCENE    scene to load (default: the project's main scene)
    GODOT_MCP_PLAYER   player node path (default: first CharacterBody2D/3D)
    GODOT_MCP_NOTES    game-specific docs appended to the play_steps tool
                       description (controls, useful watch expressions, ...)
"""

import base64
import json
import os
import pathlib
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time

HERE = pathlib.Path(__file__).resolve().parent
BRIDGE_SCRIPT = HERE / "bridge_main.gd"

PROJECT = pathlib.Path(
    sys.argv[1] if len(sys.argv) > 1 else os.environ.get("GODOT_MCP_PROJECT", os.getcwd())
).resolve()
PORT = int(os.environ.get("GODOT_MCP_PORT", "7777"))
NOTES = os.environ.get("GODOT_MCP_NOTES", "")
HEADLESS_DEFAULT = os.environ.get("GODOT_MCP_HEADLESS", "") not in ("", "0", "false")
EXTRA_ARGS = shlex.split(os.environ.get("GODOT_MCP_EXTRA_ARGS", ""))
GODOT_LOG = os.path.join(tempfile.gettempdir(), "godot_mcp", "godot_%d.log" % PORT)


def godot_bin():
    env = os.environ.get("GODOT_BIN")
    if env:
        return env
    on_path = shutil.which("godot") or shutil.which("godot4")
    if on_path:
        return on_path
    mac_default = "/Applications/Godot.app/Contents/MacOS/Godot"
    if os.path.exists(mac_default):
        return mac_default
    raise RuntimeError("no Godot binary found — set GODOT_BIN")


STEP_DOC = """Each step is an object; steps run in order, frame-accurately (60 physics frames/sec):
  {"do":"input", "actions":["ui_left"], "keys":["Z"], "frames":30}
      hold input-map actions and/or raw keyboard keys for N frames, then release.
      Use "actions" for anything in the project's input map (ui_left, ui_accept, ...)
      and "keys" for raw keys the game reads via Input.is_key_pressed.
  {"do":"wait", "frames":30}                 let the game run with no input
  {"do":"shot", "name":"my_shot"}            screenshot (path in result "shots")
  {"do":"eval", "expr":"get_node('Player').velocity"}
      evaluate a Godot Expression against the current scene root; result in "evals".
      Enums come back as ints, Vector2/3 as [x,y]/[x,y,z], nodes as their name.
  {"do":"watch", "name":"hp", "expr":"get_node('Player').hp"}
      re-evaluate every frame: emits an event whenever the value changes and adds
      the value to every telemetry sample. Persists across batches. This is how
      you get game-specific telemetry (state machines, health, scores, ...).
  {"do":"unwatch", "name":"hp"}
  {"do":"call", "node":"Player", "method":"reset_health", "args":[]}
  {"do":"set", "node":"Player", "prop":"global_position", "value":[100,200]}
  {"do":"teleport", "x":100, "y":200}        move the player node, zero velocity
  {"do":"tree", "depth":3}                   scene tree dump in result "tree"
  {"do":"sample_every", "frames":5}          telemetry sampling stride (default 5)
  {"do":"reset"}                             reload the scene fresh

The result JSON contains: "player" (final state: position, velocity, on-floor for
CharacterBody nodes, plus all watches), "events" (step markers, watch changes),
"samples" (periodic telemetry), "shots", "evals", "scene", "project"."""

if NOTES:
    STEP_DOC += "\n\nGame-specific notes:\n" + NOTES

TOOLS = [
    {
        "name": "play_steps",
        "description": "Play the game: execute a batch of input steps in the running Godot game "
        "and get back frame-by-frame telemetry and events. Launches the game first if needed.\n\n"
        + STEP_DOC
        + '\n\nExample — walk right, jump, screenshot:\n'
        '[{"do":"input","actions":["ui_right"],"frames":40},'
        '{"do":"input","actions":["ui_accept"],"frames":2},'
        '{"do":"wait","frames":50},{"do":"shot","name":"landed"}]',
        "inputSchema": {
            "type": "object",
            "properties": {
                "steps": {
                    "type": "array",
                    "items": {"type": "object"},
                    "description": "Ordered list of step objects (see tool description).",
                }
            },
            "required": ["steps"],
        },
    },
    {
        "name": "screenshot",
        "description": "Take a screenshot of the running game and return it as an image, plus "
        "the player's current state. In 2D games the camera follows the player unless the game "
        "has its own camera.",
        "inputSchema": {
            "type": "object",
            "properties": {"name": {"type": "string", "description": "File name stem (optional)."}},
        },
    },
    {
        "name": "get_state",
        "description": "Get the current player state (position, velocity, floor contact, active "
        "watch values) plus scene and project info.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "get_scene_tree",
        "description": "Dump the current scene tree (node names, types, 2D/3D positions) to "
        "understand the game's structure — useful before writing eval/watch expressions.",
        "inputSchema": {
            "type": "object",
            "properties": {"depth": {"type": "integer", "description": "Max depth (default 3)."}},
        },
    },
    {
        "name": "eval",
        "description": "Evaluate a Godot Expression against the current scene root, e.g. "
        "\"get_node('Player').velocity\" or \"get_tree().get_nodes_in_group('enemies').size()\". "
        "Read-only queries and method calls; use play_steps set/call steps to mutate.",
        "inputSchema": {
            "type": "object",
            "properties": {"expression": {"type": "string"}},
            "required": ["expression"],
        },
    },
    {
        "name": "reset_level",
        "description": "Reload the current scene fresh.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "launch_game",
        "description": "Launch the game (no-op if already running; quit_game first to switch "
        "mode). Other tools launch automatically (windowed by default); use this to launch "
        "explicitly. headless=true runs without a window: screenshots are unavailable, but "
        "combined with fast_sim=true the simulation runs as fast as the CPU allows instead of "
        "real-time 60fps — ideal for long soaks and big test batteries.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "headless": {"type": "boolean", "description": "Run without a window (no screenshots)."},
                "fast_sim": {"type": "boolean", "description": "Fixed 60fps deltas decoupled from real time (runs as fast as possible). Implies deterministic frame pacing."},
            },
        },
    },
    {
        "name": "quit_game",
        "description": "Quit the running game and close its window.",
        "inputSchema": {"type": "object", "properties": {}},
    },
]

_sock = None


def _connect(timeout=2.0):
    global _sock
    s = socket.create_connection(("127.0.0.1", PORT), timeout=timeout)
    s.settimeout(300)
    _sock = s


def _raw_request(steps):
    _sock.sendall((json.dumps(steps) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = _sock.recv(65536)
        if not chunk:
            raise OSError("bridge closed the connection")
        buf += chunk
    return json.loads(buf)


def _handshake():
    """Verify whatever is listening on the port is OUR game, not another project's."""
    res = _raw_request([])
    got = os.path.realpath(res.get("project_dir", "").rstrip("/"))
    want = os.path.realpath(str(PROJECT))
    if got != want:
        raise RuntimeError(
            "port %d is serving a different Godot project (%s, expected %s) — "
            "set GODOT_MCP_PORT to a free port for this project" % (PORT, got or "?", want)
        )


def ensure_game(headless=None, fast_sim=False):
    global _sock
    if _sock is not None:
        return "already running"
    if not (PROJECT / "project.godot").exists():
        raise RuntimeError("%s is not a Godot project (no project.godot)" % PROJECT)
    try:
        _connect()
        _handshake()
        return "connected to already-running game"
    except OSError:
        _sock = None
    os.makedirs(os.path.dirname(GODOT_LOG), exist_ok=True)
    logf = open(GODOT_LOG, "ab")
    cmd = [godot_bin(), "--path", str(PROJECT)]
    if HEADLESS_DEFAULT if headless is None else headless:
        cmd.append("--headless")
    if fast_sim:
        cmd += ["--fixed-fps", "60"]
    cmd += EXTRA_ARGS
    cmd += ["-s", str(BRIDGE_SCRIPT)]
    subprocess.Popen(
        cmd,
        stdout=logf, stderr=logf, start_new_session=True, env=os.environ.copy(),
    )
    deadline = time.time() + 25
    while time.time() < deadline:
        try:
            _connect()
            _handshake()
            return "launched game"
        except OSError:
            _sock = None
            time.sleep(0.3)
    raise RuntimeError("game did not open port %d within 25s — see %s" % (PORT, GODOT_LOG))


def bridge_request(steps):
    """Send one batch of steps, return the parsed result. Reconnects once on a dead socket."""
    global _sock
    for attempt in (1, 2):
        ensure_game()
        try:
            return _raw_request(steps)
        except OSError:
            _sock = None
            if attempt == 2:
                raise


def text(s):
    return {"type": "text", "text": s}


def tool_play_steps(args):
    return [text(json.dumps(bridge_request(args["steps"])))]


def tool_screenshot(args):
    name = args.get("name") or ("shot_%d" % int(time.time()))
    res = bridge_request([{"do": "shot", "name": name}])
    content = []
    shots = res.get("shots") or []
    if shots:
        with open(shots[-1], "rb") as f:
            data = base64.b64encode(f.read()).decode()
        content.append({"type": "image", "data": data, "mimeType": "image/png"})
    else:
        content.append(text("no screenshot produced: " + json.dumps(res.get("events"))))
    content.append(text("player: " + json.dumps(res.get("player"))))
    return content


def tool_get_state(_args):
    res = bridge_request([])
    keep = {k: res.get(k) for k in ("project", "scene", "player_node", "player")}
    return [text(json.dumps(keep))]


def tool_get_scene_tree(args):
    res = bridge_request([{"do": "tree", "depth": int(args.get("depth", 3))}])
    return [text(res.get("tree") or "(empty scene)")]


def tool_eval(args):
    res = bridge_request([{"do": "eval", "expr": args["expression"]}])
    evals = res.get("evals") or [{"error": "no eval result"}]
    return [text(json.dumps(evals[0]))]


def tool_reset_level(_args):
    res = bridge_request([{"do": "reset"}, {"do": "wait", "frames": 2}])
    return [text("level reset; player: " + json.dumps(res.get("player")))]


def tool_launch_game(args):
    return [text(ensure_game(headless=args.get("headless"), fast_sim=bool(args.get("fast_sim"))))]


def tool_quit_game(_args):
    global _sock
    try:
        bridge_request([{"do": "quit"}])
    except OSError:
        pass  # game may close the socket while acknowledging
    _sock = None
    return [text("game quit")]


TOOL_FNS = {
    "play_steps": tool_play_steps,
    "screenshot": tool_screenshot,
    "get_state": tool_get_state,
    "get_scene_tree": tool_get_scene_tree,
    "eval": tool_eval,
    "reset_level": tool_reset_level,
    "launch_game": tool_launch_game,
    "quit_game": tool_quit_game,
}


def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        method = req.get("method", "")
        req_id = req.get("id")
        params = req.get("params") or {}

        if method == "initialize":
            send({"jsonrpc": "2.0", "id": req_id, "result": {
                "protocolVersion": params.get("protocolVersion", "2025-03-26"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "godot-mcp", "version": "1.0.0"},
            }})
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": req_id, "result": {"tools": TOOLS}})
        elif method == "tools/call":
            name = params.get("name", "")
            fn = TOOL_FNS.get(name)
            if fn is None:
                send({"jsonrpc": "2.0", "id": req_id,
                      "error": {"code": -32602, "message": "unknown tool: " + name}})
                continue
            try:
                content = fn(params.get("arguments") or {})
                send({"jsonrpc": "2.0", "id": req_id,
                      "result": {"content": content, "isError": False}})
            except Exception as e:  # report tool failure in-band, keep server alive
                send({"jsonrpc": "2.0", "id": req_id,
                      "result": {"content": [text("Error: %s" % e)], "isError": True}})
        elif method == "ping":
            send({"jsonrpc": "2.0", "id": req_id, "result": {}})
        elif req_id is not None:
            send({"jsonrpc": "2.0", "id": req_id,
                  "error": {"code": -32601, "message": "method not found: " + method}})
        # notifications (no id) are ignored


if __name__ == "__main__":
    main()
