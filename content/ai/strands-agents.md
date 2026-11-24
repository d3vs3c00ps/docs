---
title: Strands Agents
description: A model-driven agent SDK — defining an agent in a few lines, tools as decorated functions, MCP support, and pointing it at a local model
tags: [ai, agents, sdk, python, mcp]
type: howto
status: complete
---

# Strands Agents

> [!note] Partly tested
> Tested with strands-agents 1.65.0 against a scripted fake model that calls the
> offered tool once. So the agent loop, the tool schema, both providers and MCP are
> tested; how well a real local model calls tools is not.

[Strands Agents](https://strandsagents.com/) is an SDK for building AI agents, from
the `strands-agents` organisation, with Python and TypeScript implementations.

Its framing is **model-driven**: rather than encoding a fixed graph of steps, you give
the model a prompt and a set of tools and let it plan. That is a deliberate contrast
with the node-and-edge orchestration of LangGraph and similar frameworks.

## Where it fits in this section

Everything else here is about **running** models locally — engines, quantization,
serving. This is about **building something with one**, which is the other half.

The relevant property for these notes: Strands supports Ollama and LiteLLM as model
providers in the Python SDK, so an agent can run entirely against
[[ai/llama-cpp|your own hardware]] with no API key and nothing leaving the machine.

## Installing

```bash
pip install strands-agents strands-agents-tools
```

The model providers are extras. For the local ones below, install them too:

```bash
pip install 'strands-agents[ollama,openai]'
```

> [!note] Install the extras
> With the base package alone, `from strands.models.ollama import OllamaModel` fails
> with `No module named 'ollama'`, and the OpenAI provider fails the same way.
> LiteLLM is the `litellm` extra.

## A minimal agent

With no `model`, `Agent()` uses Amazon Bedrock (a Claude model), so this needs AWS
credentials. Without them it stops with `NoCredentialsError`. To run it locally, pass
a `model` as shown in [[#Pointing it at a local model]].

```python
from strands import Agent

agent = Agent()
response = agent("What is the capital of France?")
print(response)
```

## Tools

A tool is a decorated function. The docstring and type hints become the schema the
model sees:

```python
from strands import Agent, tool


@tool
def check_port(host: str, port: int) -> str:
    """Check whether a TCP port is open on a host.

    Args:
        host: The hostname or IP address to check.
        port: The TCP port number.
    """
    import socket

    with socket.socket() as s:
        s.settimeout(2)
        try:
            s.connect((host, port))
            return f"{host}:{port} is open"
        except OSError as e:
            return f"{host}:{port} is closed ({e})"


agent = Agent(tools=[check_port])
print(agent("Is port 443 open on example.com?"))
```

> [!important] The docstring is the tool's interface, not documentation
> The model decides whether to call a tool based entirely on its name, its docstring
> and its parameter types. A vague docstring means the tool is never invoked, or is
> invoked with nonsense arguments — and the failure looks like the model being stupid
> rather than the description being bad.
>
> This is the same principle as a skill's `description` field in
> agent-skills: write it for the model deciding whether to use it, not for a
> human reading the source.

## Pointing it at a local model

```python
from strands import Agent
from strands.models.ollama import OllamaModel

model = OllamaModel(
    host="http://localhost:11434",
    model_id="qwen3.6:27b",
)

agent = Agent(model=model, tools=[check_port])
print(agent("Check whether port 22 is open on 10.0.0.5"))
```

Against [[ai/llama-swap]] or a bare `llama-server`, use the OpenAI-compatible
provider — the endpoint is the same one everything else in this section uses:

```python
from strands.models.openai import OpenAIModel

model = OpenAIModel(
    client_args={"api_key": "local", "base_url": "http://localhost:8080/v1"},
    model_id="qwen-27b",
)
```

> [!warning] Tool calling is where small local models fall down
> An agent framework is almost entirely tool calling, and the model has to emit
> well-formed structured calls reliably, repeatedly, across a multi-step plan. Below
> roughly 27B parameters this becomes unreliable — malformed arguments, invented tool
> names, or plausible text where a call should be.
>
> This is the same limitation noted in [[ai/zed-local-llm]] and [[ai/models]], and it
> bites harder here: a chat interface tolerates one bad response, an agent loop
> compounds it. Test with your actual model before designing around it.

## MCP

Strands consumes [[ai/mcp|MCP]] servers, so any tool you have already exposed that
way is available without rewriting:

```python
from mcp import stdio_client, StdioServerParameters
from strands import Agent
from strands.tools.mcp import MCPClient

mcp_client = MCPClient(
    lambda: stdio_client(
        StdioServerParameters(command="python", args=["k8s_mcp.py"])
    )
)

with mcp_client:
    agent = Agent(tools=mcp_client.list_tools_sync())
    print(agent("What is the status of the api-server pod in kube-system?"))
```

That composes well: write the tool once as an MCP server, use it from your editor and
from an agent.

## Evaluating it

**Where it is a reasonable choice:**

- The agent's job is genuinely open-ended — "investigate this, using whatever tools
  make sense" — which is what model-driven planning suits.
- You already have MCP servers.
- You want the same code to run against a local model in development and a hosted one
  in production. The provider abstraction is the main practical benefit.

**Where it is not:**

- The workflow is a **known sequence**. If you can draw the flowchart, write the
  flowchart — a script calling an LLM at three specific points is more reliable,
  cheaper and far easier to debug than an agent that rediscovers the plan each run.
- You need reproducibility. A model-driven agent takes a different path on each
  invocation by design, which is difficult to test and to audit.
- The task is small. `curl` against `/v1/chat/completions` is a legitimate answer, and
  is what http-client shows.

> [!note] The deployment story is AWS-shaped
> Documentation leans heavily on Amazon Bedrock and AgentCore, with Lambda, Fargate
> and EKS as deployment targets. None of that is required — the SDK runs anywhere
> Python does, including against Ollama with no cloud account — but expect to filter
> AWS-specific material when reading the docs.

> [!danger] An agent with tools executes actions, and the model chooses which
> The tool in the first example only opens a socket. The moment a tool runs a command,
> writes a file or calls an API, the model's plan becomes an execution path you did
> not review.
>
> Give tools the narrowest possible capability, make destructive operations require
> explicit confirmation, and run the whole thing somewhere bounded — a container, a
> dedicated service account, a git worktree. The reasoning in
> [[ai/msty-claw]] about sandboxing applies identically here.

## Where to go next

- [[ai/mcp]] — writing the tools an agent consumes
- [[ai/models]] — which local models handle tool calling adequately
- [[ai/llama-swap]] — the endpoint to point it at
- [[dev/agent-skills]] — the other way to shape agent behaviour

## Sources

- [Strands Agents documentation](https://strandsagents.com/docs/user-guide/quickstart/overview/)

<!-- uplink -->
Part of [[ai/index|Local LLMs]].
