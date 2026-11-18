# RouteDocs.jl

[![CI](https://github.com/JuliaServices/RouteDocs.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/JuliaServices/RouteDocs.jl/actions/workflows/ci.yml)

Document an HTTP API's routes once, in Julia, and generate two things from that
one description:

- an [OpenAPI 3.1](https://spec.openapis.org/oas/v3.1.0) document, and
- [Model Context Protocol](https://modelcontextprotocol.io) (MCP) tool definitions,
  so AI agents can call the same routes.

Request and response bodies are your own structs. Their JSON shape, types, and
defaults come from the struct, and each field's description from its field
docstring, so the documentation cannot drift from what the handler parses.
`RouteDocs.problems` lists every gap: a registered route with no documentation, a
field with no docstring, a tool with no title, a backticked tool name that no
tool has.

RouteDocs is meant for a build step or a test, not for a running server: it
reads docstrings and struct definitions by reflection.

## Install

```julia
using Pkg
Pkg.add(url = "https://github.com/JuliaServices/RouteDocs.jl")
```

## Document two routes

```julia
using RouteDocs, StructUtils, JSON

"A note."
@kwarg struct Note
    "The note's ID."
    id::String
    "What the note says."
    text::String
end

"A new note."
@kwarg struct CreateNoteRequest
    "What the note says."
    text::String
end

RouteDocs.PATH_PARAMS["note_id"] = "Note ID. Get it from `create_note`."

RouteDocs.group("notes"; label = "Notes", description = "Short notes that people write.")

RouteDocs.endpoint("POST /v1/notes";
    summary = "Write a note",
    description = "Saves a new note.",
    access = "Any signed-in user.",
    body = CreateNoteRequest,
    response = Note,
    status = 201,
    returns = "The new note, including its `id`.",
    mcp = RouteDocs.tool("create_note"; title = "Write a note"))

RouteDocs.endpoint("GET /v1/notes/{note_id}";
    summary = "Read a note",
    description = "Returns one note.",
    access = "The note's writer.",
    response = Note,
    returns = "The note.",
    errors = [404 => "No note has this ID."],
    mcp = RouteDocs.tool("get_note"; title = "Read a note"))
```

Every endpoint is either a tool (`mcp = RouteDocs.tool(...)`) or left out of the
MCP tools on purpose (`mcp = RouteDocs.excluded("why")`). An endpoint with
`audience = :internal` (any symbol other than the default `:official`) is
documented but left out of both outputs.

## Write OpenAPI and the MCP tool list

```julia
routes = Set([("POST", "/v1/notes"), ("GET", "/v1/notes/{note_id}")])  # what your router registers
issues = RouteDocs.problems(; routes)
isempty(issues) || error(join(issues, "\n"))

openapi = RouteDocs.openapi(;
    title = "Notes API",
    version = "1.0.0",
    servers = ["https://api.example.com"],
    security_schemes = Dict("token" => Dict("type" => "http", "scheme" => "bearer")),
    security = endpoint -> [Dict("token" => String[])])
write("openapi.json", JSON.json(openapi; pretty = 2))

tools = RouteDocs.mcp_tools(; service = "Notes")
write("tools.json", JSON.json([RouteDocs.tool_definition(t) for t in tools]; pretty = 2))
```

Each `RouteDocs.McpTool` also says how to call its route: `method`, `path`, and
`arguments`, which map each flat tool argument to its path parameter, query
parameter, or body field. An MCP server uses that to turn a tool call into a
request to the API.

Keys are written in a fixed order, so generated files diff cleanly when the
documentation changes.

## Documentation format

See the docstrings of `RouteDocs.endpoint`, `RouteDocs.tool`, and
`RouteDocs.param` for every keyword. Text written as wrapped source lines is
joined into flowing paragraphs; blank lines, list items, and indented lines keep
their breaks.

Field names in the JSON Schema are the struct's field names; field renames from
StructUtils tags are not read.
