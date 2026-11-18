const METHODS = ("GET", "POST", "PUT", "PATCH", "DELETE")

"A path, query, or tool parameter that is not a field of the JSON request body."
struct Param
    name::String
    type::Any
    required::Bool
    description::String
    enum::Vector{String}
    example::Any
end

"""
    param(name, type = String; description, required = false, enum = String[], example = nothing)

Document one query parameter (or override one path parameter). `type` is a Julia
type such as `String`, `Int`, `Bool`, `Date`, or `Vector{String}`; a vector query
parameter repeats its name once per value.
"""
param(name::AbstractString, type = String; description::AbstractString,
      required::Bool = false, enum = String[], example = nothing) =
    Param(String(name), type, required, String(description), String.(enum), example)

"""
Agent-facing options for an endpoint that is exposed as an MCP tool.

- `name`: the tool name, `verb_object` in snake case (for example `create_order`).
- `title`: a short human title shown by MCP hosts.
- `guidance`: what an agent should know beyond the endpoint description: which
  tool to call first to get an ID, which sibling tool to use instead, and common
  mistakes. Plain sentences.
- `destructive`: the call removes data or cannot be undone (deletes, cancels,
  refunds). Hosts ask the person before running destructive tools.
- `idempotent`: repeating the same call has no further effect. Defaults to true
  for PUT and DELETE and false for POST.
- `widget`: the display widget for the result, or `nothing` for text only.
- `rename`: maps a body field name to a different argument name when it would
  collide with a path or query parameter.
- `omit`: body fields agents may not set; the server uses their defaults. Use it
  for values only a person should give, such as a legal signature.
- `auto_key`: a body field holding an idempotency key (such as `operation_key`)
  that the MCP server fills in when the agent leaves it out, so the argument is
  optional. [`mcp_tools`](@ref)'s `auto_key_note` tells agents how the server
  picks the key.
- `defaults`: values the MCP server sends for query parameters the agent leaves
  out, such as `(limit = 50,)`. Use it to keep a tool result small enough for an
  assistant when the route itself returns everything by default.
"""
struct Tool
    name::String
    title::String
    guidance::String
    destructive::Bool
    idempotent::Union{Bool,Nothing}
    widget::Union{Symbol,Nothing}
    rename::Dict{String,String}
    omit::Vector{String}
    auto_key::String
    defaults::Dict{String,Any}
end

"See [`Tool`](@ref)."
tool(name::AbstractString; title::AbstractString, guidance::AbstractString = "",
     destructive::Bool = false, idempotent::Union{Bool,Nothing} = nothing,
     widget::Union{Symbol,Nothing} = nothing, rename = Dict{String,String}(),
     omit = String[], auto_key::AbstractString = "", defaults = (;)) =
    Tool(String(name), String(title), strip_text(guidance), destructive, idempotent, widget,
         Dict{String,String}(String(k) => String(v) for (k, v) in pairs(rename)),
         String.(collect(omit)), String(auto_key),
         Dict{String,Any}(String(k) => v for (k, v) in pairs(defaults)))

"An endpoint deliberately left out of the MCP tools, and why."
struct Exclusion
    reason::String
end

"""
    excluded(reason)

Leave an endpoint out of the MCP tools. The reason names what an agent should use
instead when there is an alternative, for example "CSV download; list_orders
returns the same rows as JSON".
"""
excluded(reason::AbstractString) = Exclusion(String(reason))

"A documented group of endpoints: one OpenAPI tag."
struct Group
    slug::String
    label::String
    description::String
end

struct Endpoint
    method::String
    path::String
    group::String
    summary::String
    description::String
    access::String
    audience::Symbol
    path_params::Vector{Param}
    query::Vector{Param}
    body::Any
    body_required::Bool
    required::Vector{String}
    fields::Dict{String,Dict{String,Any}}
    response::Any
    returns::String
    status::Int
    content_type::String
    errors::Vector{Pair{Int,String}}
    notifies::Bool
    moves_money::Bool
    mcp::Union{Tool,Exclusion}
    source::String
end

"Every group documented so far, in documentation order."
const GROUPS = Group[]
"Every endpoint documented so far, in documentation order."
const ENDPOINTS = Endpoint[]
const CURRENT_GROUP = Ref("")

"""
Descriptions of path parameters shared by many endpoints, by name, such as
`"user_id" => "User ID."`. Fill it before documenting endpoints: [`endpoint`](@ref)
copies the description of each `{name}` in its path from here, unless its
`params` keyword gives one.
"""
const PATH_PARAMS = Dict{String,String}()

"Forget every documented group and endpoint, before documenting them again."
function reset!()
    empty!(GROUPS)
    empty!(ENDPOINTS)
    CURRENT_GROUP[] = ""
    return nothing
end

"""
    group(slug; label, description)

Start a section of the API. Endpoints documented after this call belong to it
until the next `group` call.
"""
function group(slug::AbstractString; label::AbstractString, description::AbstractString)
    any(g -> g.slug == slug, GROUPS) && throw(ArgumentError("API group $(slug) is defined twice"))
    push!(GROUPS, Group(String(slug), String(label), strip_text(description)))
    CURRENT_GROUP[] = String(slug)
    return nothing
end

"""
    endpoint("METHOD /v1/path/{param}"; summary, description, access, returns, mcp, ...)

Document one route in the current [`group`](@ref). The path uses `{name}` for
each path parameter. Shared names take their description from
[`PATH_PARAMS`](@ref), and `params = (name = "description",)` overrides or adds
one.

Keywords:
- `summary`: one line, an imperative phrase ("Add one item to an order").
- `description`: what the endpoint does, its rules, and its side effects, in plain
  sentences for someone who has never seen the code.
- `access`: who may call it ("Account admins", "Any signed-in user", "Anyone").
- `returns`: what the response contains.
- `query`: a vector of [`param`](@ref)s.
- `body`: the request struct parsed by the handler. Its field docstrings are the
  field documentation. `body_required = false` when the body may be omitted.
- `required`: body fields the handler rejects when missing or blank, beyond the
  fields that have no default.
- `fields`: JSON Schema keywords added to a body field, for example
  `(status = (enum = ["open", "closed"],),)`.
- `response`: the Julia type serialized as the response, when there is one.
- `status`: the success status (200, 201, or 204).
- `content_type`: the success media type when it is not JSON.
- `errors`: `status => "when it happens"` pairs worth knowing about.
- `notifies`: the call sends email or text messages to people.
- `moves_money`: the call charges, refunds, or records money.
- `audience`: `:official` (default) for the public API. Any other symbol, such
  as `:internal`, documents a route that [`openapi`](@ref) and
  [`mcp_tools`](@ref) leave out.
- `mcp`: a [`tool`](@ref) or an [`excluded`](@ref) reason.
- `source`: where the documentation is, for [`problems`](@ref) messages. It
  defaults to the `directory/file:line` of the call.
"""
function endpoint(route::AbstractString;
                  summary::AbstractString,
                  description::AbstractString = "",
                  access::AbstractString = "",
                  returns::AbstractString = "",
                  params = (;),
                  query = Param[],
                  body = nothing,
                  body_required::Bool = body !== nothing,
                  required = String[],
                  fields = (;),
                  response = nothing,
                  status::Integer = 200,
                  content_type::AbstractString = "application/json",
                  errors = Pair{Int,String}[],
                  notifies::Bool = false,
                  moves_money::Bool = false,
                  audience::Symbol = :official,
                  mcp::Union{Tool,Exclusion} = Exclusion(""),
                  source::AbstractString = caller_source())
    isempty(CURRENT_GROUP[]) && throw(ArgumentError("call RouteDocs.group before documenting $(route)"))
    parts = split(strip(route), ' '; limit = 2)
    length(parts) == 2 || throw(ArgumentError("route must look like \"GET /v1/...\": $(route)"))
    method, path = String(parts[1]), String(parts[2])
    method in METHODS || throw(ArgumentError("unknown method in $(route)"))
    overrides = Dict{String,String}(String(k) => String(v) for (k, v) in pairs(params))
    path_params = Param[]
    for name in path_param_names(path)
        text = get(overrides, name, get(PATH_PARAMS, name, ""))
        push!(path_params, Param(name, String, true, text, String[], nothing))
    end
    for name in keys(overrides)
        name in path_param_names(path) ||
            throw(ArgumentError("$(route) documents path parameter $(name), which is not in its path"))
    end
    push!(ENDPOINTS, Endpoint(
        method, path, CURRENT_GROUP[], strip_text(summary), strip_text(description),
        strip_text(access), audience, path_params, collect(Param, query), body, body_required,
        String.(collect(required)),
        Dict{String,Dict{String,Any}}(String(k) => Dict{String,Any}(String(kk) => vv for (kk, vv) in pairs(v))
                                      for (k, v) in pairs(fields)),
        response, strip_text(returns), Int(status), String(content_type),
        Pair{Int,String}[Int(first(e)) => strip_text(last(e)) for e in errors],
        notifies, moves_money, mcp, String(source)))
    return nothing
end

"The `directory/file:line` of the first caller outside this package."
function caller_source()
    for frame in stacktrace()
        file = String(frame.file)
        dirname(file) == @__DIR__() && continue
        return string(joinpath(basename(dirname(file)), basename(file)), ":", frame.line)
    end
    return "unknown"
end

"""
    strip_text(text) -> String

Trim `text` and join the lines of each paragraph, so documentation written as
wrapped source lines reads as flowing sentences. Blank lines, list items
(`- `, `1. `), and indented lines keep their line breaks.
"""
function strip_text(text::AbstractString)
    lines = split(strip(text), '\n')
    out = IOBuffer()
    for (i, line) in enumerate(lines)
        if i > 1
            prev = lines[i-1]
            keep = isempty(strip(line)) || isempty(strip(prev)) ||
                occursin(r"^\s*(-|\*|\d+\.)\s", line) || startswith(line, "    ")
            print(out, keep ? "\n" : " ")
        end
        print(out, rstrip(line))
    end
    return String(take!(out))
end

"The `{name}` segments of a documented path, in order."
path_param_names(path::AbstractString) = [String(m.captures[1]) for m in eachmatch(r"\{([a-z_]+)\}", path)]
