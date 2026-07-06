# godot-mcp

An MCP server that lets Claude (or any MCP client) **play a Godot 4 game**:
send frame-accurate inputs, read back telemetry and events, take screenshots,
query and mutate the scene. Works with any Godot 4 project with **zero files
installed into the game** — the in-game half is injected at launch via Godot's
`-s` script flag.

No dependencies: Python stdlib + your Godot binary.

## Setup (per game project)

Add `.mcp.json` at the game project root:

```json
{
  "mcpServers": {
    "godot": {
      "command": "python3",
      "args": ["/Users/evan/Coding/godot-mcp/server.py"],
      "env": {
        "GODOT_MCP_NOTES": "Controls: ui_left/ui_right move, ui_accept jumps. ..."
      }
    }
  }
}
```

`GODOT_MCP_NOTES` is optional but recommended: it's appended to the `play_steps`
tool description, so a fresh Claude session knows the game's controls and
useful watch expressions without reading the source.

Approve the server on the next Claude Code session in that project. Done.

## Tools

| Tool | What it does |
|---|---|
| `play_steps` | Execute a batch of input steps frame-accurately; returns telemetry samples + events |
| `screenshot` | Returns a PNG of the game view directly in the tool result |
| `get_state` | Player position/velocity/floor + active watch values |
| `get_scene_tree` | Node names/types/positions — orientation before writing expressions |
| `eval` | Evaluate a Godot Expression against the current scene |
| `reset_level` | Reload the scene fresh |
| `launch_game` / `quit_game` | Lifecycle (all tools auto-launch on demand) |

Game-specific telemetry comes from **watch expressions** rather than code:

```json
[{"do": "watch", "name": "hp", "expr": "get_node('Player').hp"},
 {"do": "input", "actions": ["ui_right"], "frames": 60}]
```

emits an event every time the value changes and includes it in every sample.
The full step language is documented in the `play_steps` tool description and
at the top of `bridge_main.gd`.

## How it works

```
Claude ⇄ (MCP stdio) ⇄ server.py ⇄ (TCP 127.0.0.1:7777) ⇄ bridge_main.gd ⇄ game
```

`server.py` launches `godot --path <project> -s bridge_main.gd`. That script
boots a custom SceneTree: it instantiates the project's autoloads and main
scene, then runs a bridge node that executes step batches in
`_physics_process` and replies with newline-delimited JSON.

## Configuration (env vars, set in `.mcp.json`)

| Var | Default | Purpose |
|---|---|---|
| `GODOT_MCP_PROJECT` | cwd | Game project dir (or pass as argv[1]) |
| `GODOT_BIN` | `godot` on PATH, else /Applications/Godot.app | Godot 4 binary |
| `GODOT_MCP_PORT` | 7777 | Bridge TCP port — set per project to run several games at once |
| `GODOT_MCP_SCENE` | project main scene | Scene to load |
| `GODOT_MCP_PLAYER` | first CharacterBody2D/3D | "Player" node for telemetry/camera/teleport |
| `GODOT_MCP_NOTES` | — | Game-specific docs appended to `play_steps` |

## Notes & caveats

- The game runs **windowed** (screenshots need a render target; headless would
  break them). You can watch Claude play.
- In 2D, a follow-camera is attached to the player unless the game already has
  a current camera. Screenshots are the previous rendered frame (~16 ms stale).
- The server verifies the project identity of whatever is on the port, so two
  projects can't cross-talk; they just need distinct `GODOT_MCP_PORT`s to run
  simultaneously.
- Autoloads are re-created manually (script mode skips them); plain scripts and
  scene autoloads are supported.
- Raw-key input (`"keys": ["Z"]`) covers games that read
  `Input.is_key_pressed()` directly; input-map actions cover everything else.
  Frames are physics frames (60/s by default).
- Dev tool: the bridge listens on localhost only and can mutate game state by
  design. Don't ship it in a release build.
