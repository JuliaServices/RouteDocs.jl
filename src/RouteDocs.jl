"""
    RouteDocs

Document an HTTP API once, in Julia, and generate its OpenAPI 3.1 document and
its Model Context Protocol (MCP) tool definitions from that one description.

Routes are documented with [`group`](@ref) and [`endpoint`](@ref), usually in a
file next to the code that serves them. Request and response bodies are Julia
structs: their JSON shape, types, and defaults are read from the struct, and
each field's description from its field docstring. [`openapi`](@ref) and
[`mcp_tools`](@ref) build the outputs, and [`problems`](@ref) lists every gap
that would leave one of them incomplete.

Documentation is collected in [`ENDPOINTS`](@ref) and [`GROUPS`](@ref) as the
documenting code runs. Call [`reset!`](@ref) before loading it again.
"""
module RouteDocs

using Dates, JSON, StructUtils

include("spec.jl")
include("schema.jl")
include("mcp.jl")
include("openapi.jl")
include("checks.jl")

end
