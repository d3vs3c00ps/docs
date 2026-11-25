---
title: Model Context Protocol
description: The JSON-RPC protocol agents use to call external tools — using existing servers, and writing your own in Python or Go
tags: [ai, mcp, tooling, python, go]
type: concept
status: complete
---

# Model Context Protocol

> [!note] Partly tested
> Tested on Linux with the Python SDK `mcp` 2.3.0, the Go SDKs go-sdk v1.8.0 and
> mcp-go v1.6.0, and `@modelcontextprotocol/server-filesystem`, by speaking JSON-RPC
> to each server directly. Zed, the MCP Inspector UI and `mcp-remote` are not
> tested.

MCP is a JSON-RPC 2.0 protocol letting AI agents call external tools, read data
sources and use prompt templates through one standard interface. The usual framing is
"USB-C for AI": one protocol connecting any agent to any tool.

## Concepts

An MCP server exposes three kinds of capability:

| Capability | What it is | Example |
| --- | --- | --- |
| **Tools** | Functions the agent can call | Query a database, run a linter, search logs |
| **Resources** | Read-only data the agent can access | File contents, config values, API responses |
| **Prompts** | Predefined prompt templates | "Summarise this PR", "Review this Go code" |

The client discovers what a server offers, then calls tools or reads resources during
a conversation.

### Transports

- **stdio** — the agent spawns the server as a subprocess and talks over
  stdin/stdout. Simplest, and the norm for local use.
- **Streamable HTTP** — the server runs as an HTTP service, for remote or shared
  servers. It replaced the older **HTTP with SSE** transport in the 2025-03-26
  version of the spec; the Python SDK serves it with
  `mcp.run(transport="streamable-http")`, on port 8000 at `/mcp`.

Zed natively supports **stdio only**. Remote HTTP servers need the `mcp-remote`
bridge.

> [!warning] An MCP server runs with your privileges
> A server configured in your editor is a subprocess with your user's access to the
> filesystem, network and credentials — and the agent decides when to invoke it.
> Treat adding one exactly like installing a shell plugin: read what it does, prefer
> servers you can inspect, and scope filesystem servers to a specific directory
> rather than to `/`.

## Using existing servers in Zed

Add them to `settings.json` under `context_servers`:

```json
{
  "context_servers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/project"]
    },
    "git": {
      "command": "uvx",
      "args": ["mcp-server-git", "--repository", "/path/to/repo"]
    }
  }
}
```

`@modelcontextprotocol/server-filesystem` 2.4.0 needs Node.js 24 or later. On an
older Node.js (Debian 13 ships 20) it crashes at start with "does not provide an
export named 'getSystemErrorMessage'". The git server needs `uv`, for `uvx`.

In the agent panel, indicator dots show server status — green for healthy, red or
grey for failed to start or crashed.

### Servers worth having

| Server | Package | Purpose |
| --- | --- | --- |
| Filesystem | `@modelcontextprotocol/server-filesystem` | Read and write files outside the workspace |
| Git | `mcp-server-git` (Python, run with `uvx`) | Log, diff, status, commit |

> [!warning] Some well-known servers are gone
> There is no `@modelcontextprotocol/server-git` on npm: the git server is the Python
> package `mcp-server-git`. `@modelcontextprotocol/server-postgres` is archived and
> `@modelcontextprotocol/server-brave-search` is deprecated. Look in the registry for
> maintained replacements.

The [server registry](https://github.com/modelcontextprotocol/servers) has many more.

### Zed's limitations

- Only **tools** and **prompts** are supported — not resources or sampling.
- Only **stdio** natively; HTTP needs `mcp-remote`.
- Tool reliability depends heavily on the model. Below about 27B, tool calling gets
  unreliable — see [[ai/models]].
- Naming the server in your prompt helps the agent route to the right tool.

## Writing a server in Python

The official [Python SDK](https://github.com/modelcontextprotocol/python-sdk), with
its `MCPServer` API. Python 3.10+.

```bash
pip install "mcp[cli]"
```

A server exposing one tool:

```python
# k8s_mcp.py
import subprocess

from mcp.server.mcpserver import MCPServer

mcp = MCPServer("k8s-tools")


@mcp.tool()
def get_pod_status(namespace: str, pod_name: str) -> str:
    """Get the status of a Kubernetes pod."""
    result = subprocess.run(
        ["kubectl", "get", "pod", pod_name, "-n", namespace, "-o", "json"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return f"Error: {result.stderr}"
    return result.stdout


if __name__ == "__main__":
    mcp.run(transport="stdio")
```

> [!note] `FastMCP` is `MCPServer` in mcp 2.x
> `pip install "mcp[cli]"` installs mcp 2.x (2.3.0 tested), where
> `from mcp.server.fastmcp import FastMCP` fails with "FastMCP was renamed to
> MCPServer". The decorators and `mcp.run()` are the same. Code written for 1.x needs
> `pip install "mcp[cli]<2"`.

> [!important] Three rules for Python MCP servers
> 1. **Never write to stdout.** It corrupts the JSON-RPC stream. Use `stderr` or the
>    `logging` module — a stray `print()` is the most common reason a server starts
>    but exposes no tools.
> 2. **Use type hints.** The SDK generates JSON schemas from your signatures.
>    Without hints, every parameter becomes a plain string (tested with mcp 2.3.0),
>    so an `int` or a `list` argument loses its type.
> 3. **Docstrings become tool descriptions.** The agent reads them to decide when to
>    call the tool, so write them for that audience.

Adding a resource:

```python
@mcp.resource("config://cluster-info")
def get_cluster_info() -> str:
    """Current Kubernetes cluster configuration."""
    result = subprocess.run(
        ["kubectl", "cluster-info"],
        capture_output=True,
        text=True,
    )
    return result.stdout
```

Registering it:

```json
{
  "context_servers": {
    "k8s-tools": {
      "command": "python",
      "args": ["k8s_mcp.py"],
      "env": {
        "KUBECONFIG": "/home/user/.kube/config"
      }
    }
  }
}
```

## Writing a server in Go

The official [Go SDK](https://github.com/modelcontextprotocol/go-sdk) has one
package, `mcp`. Tool arguments are a struct: the SDK builds the JSON schema from it,
and fields without `omitempty` are required.

```bash
go get github.com/modelcontextprotocol/go-sdk/mcp
```

```go
// main.go
package main

import (
	"context"
	"fmt"
	"log"
	"os/exec"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type podArgs struct {
	Namespace string `json:"namespace" jsonschema:"Kubernetes namespace"`
	PodName   string `json:"pod_name" jsonschema:"Name of the pod"`
}

func getPodStatus(ctx context.Context, req *mcp.CallToolRequest, args podArgs) (*mcp.CallToolResult, any, error) {
	out, err := exec.CommandContext(ctx,
		"kubectl", "get", "pod", args.PodName, "-n", args.Namespace, "-o", "json").Output()
	if err != nil {
		// A handler error is sent to the client as a tool error, not a crash.
		return nil, nil, fmt.Errorf("kubectl error: %w", err)
	}
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(out)}}}, nil, nil
}

func main() {
	s := mcp.NewServer(&mcp.Implementation{Name: "k8s-tools", Version: "1.0.0"}, nil)
	mcp.AddTool(s, &mcp.Tool{Name: "get_pod_status", Description: "Get the status of a Kubernetes pod"}, getPodStatus)
	if err := s.Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		log.Fatal(err)
	}
}
```

The community [mcp-go](https://github.com/mark3labs/mcp-go) SDK builds the schema
with option functions instead of a struct:

```bash
go get github.com/mark3labs/mcp-go
```

```go
// main.go
package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"

	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"
)

func main() {
	s := server.NewMCPServer("k8s-tools", "1.0.0")

	tool := mcp.NewTool("get_pod_status",
		mcp.WithDescription("Get the status of a Kubernetes pod"),
		mcp.WithString("namespace", mcp.Required(), mcp.Description("Kubernetes namespace")),
		mcp.WithString("pod_name", mcp.Required(), mcp.Description("Name of the pod")),
	)

	s.AddTool(tool, func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		ns, ok := req.GetArguments()["namespace"].(string)
		if !ok {
			return mcp.NewToolResultError("namespace must be a string"), nil
		}
		pod, ok := req.GetArguments()["pod_name"].(string)
		if !ok {
			return mcp.NewToolResultError("pod_name must be a string"), nil
		}

		out, err := exec.CommandContext(ctx,
			"kubectl", "get", "pod", pod, "-n", ns, "-o", "json").Output()
		if err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("kubectl error: %v", err)), nil
		}
		return mcp.NewToolResultText(string(out)), nil
	})

	if err := server.ServeStdio(s); err != nil {
		fmt.Fprintf(os.Stderr, "server error: %v\n", err)
		os.Exit(1)
	}
}
```

**Why Go for MCP servers** — compiled binaries start instantly with no interpreter
startup cost, which matters when the agent spawns the server per session; goroutines
handle concurrent tool calls; the type system catches protocol mismatches at compile
time; and distribution is a single binary.

Register it the same way:

```bash
go build -o k8s-mcp-server .
```

```json
{
  "context_servers": {
    "k8s-tools": {
      "command": "/path/to/k8s-mcp-server",
      "env": {
        "KUBECONFIG": "/home/user/.kube/config"
      }
    }
  }
}
```

## Testing and debugging

The [MCP Inspector](https://github.com/modelcontextprotocol/inspector) gives a web UI
for calling tools, browsing resources and watching raw JSON-RPC:

```bash
npx @modelcontextprotocol/inspector python k8s_mcp.py
```

Or test the transport by hand:

```bash
echo '{"jsonrpc":"2.0","method":"tools/list","id":1}' | python k8s_mcp.py
```

| Symptom | Cause | Fix |
| --- | --- | --- |
| Server starts, no tools appear | Something wrote to stdout | Remove every `print()`; use `stderr` |
| "Connection refused" in Zed | Server crashed at startup | Check its logs; test with the inspector |
| Tool calls fail silently | Model handles function calling poorly | Use a larger model |
| Zed does not detect the server | Wrong command path | Use absolute paths in `context_servers` |

## Where to go next

- [[dev/agent-skills]] — the other way to extend an agent, without a running process
- [[ai/zed-local-llm]] — the editor these servers plug into

## Further reading

- [MCP specification](https://modelcontextprotocol.io/)
- [Python SDK reference](https://modelcontextprotocol.github.io/python-sdk/)
- [Go SDK repository](https://github.com/modelcontextprotocol/go-sdk)
- [Server registry](https://github.com/modelcontextprotocol/servers)

<!-- uplink -->
Part of [[ai/index|Local LLMs]].
