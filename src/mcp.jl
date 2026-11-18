"One argument of an MCP tool and where its value goes in the HTTP request."
struct ToolArgument
    name::String
    location::Symbol   # :path, :query, or :body
    target::String     # the path parameter, query parameter, or body field name
    required::Bool
    schema::Dict{String,Any}
end

"An MCP tool generated from one documented endpoint."
struct McpTool
    name::String
    title::String
    description::String
    input_schema::Dict{String,Any}
    annotations::Dict{String,Any}
    method::String
    path::String
    arguments::Vector{ToolArgument}
    body_required::Bool
    widget::String
    auto_key::String
    endpoint::Endpoint
end

"Whether `e` is an official endpoint documented with a [`tool`](@ref)."
is_tool(e::Endpoint) = e.audience === :official && e.mcp isa Tool

"""
    tool_arguments(e::Endpoint; auto_key_note = "") -> Vector{ToolArgument}

The flat argument list of the tool for `e`: path parameters first, then query
parameters, then the fields of the JSON body. Agents pass one object of named
values instead of separate path, query, and body objects. The tool's `auto_key`
argument is optional, and its description ends with `auto_key_note`.
"""
function tool_arguments(e::Endpoint; auto_key_note::AbstractString = "")
    t = e.mcp::Tool
    args = ToolArgument[]
    for p in e.path_params
        push!(args, ToolArgument(p.name, :path, p.name, true,
            Dict{String,Any}("type" => "string", "minLength" => 1, "description" => p.description)))
    end
    for p in e.query
        s = param_schema(p)
        defaulted = haskey(t.defaults, p.name)
        defaulted && (s["default"] = t.defaults[p.name])
        push!(args, ToolArgument(p.name, :query, p.name, p.required && !defaulted, s))
    end
    whole_body = !is_object_struct(something(e.body, Nothing))
    for (field, s, required) in body_fields(e)
        field in t.omit && continue
        if field == t.auto_key
            required = false
            s = copy(s)
            delete!(s, "minLength")
            s["description"] = join(filter(!isempty, [get(s, "description", ""), auto_key_note]), " ")
        end
        # A body that is not an object (such as a list) is one argument sent as the whole body.
        push!(args, ToolArgument(get(t.rename, field, field), :body, whole_body ? "" : field, required, s))
    end
    return args
end

function param_schema(p::Param)
    s = schema(p.type)
    isempty(p.enum) || (s["enum"] = copy(p.enum))
    p.example === nothing || (s["examples"] = Any[p.example])
    s["description"] = p.description
    return s
end

"""
    body_fields(e) -> Vector{Tuple{String,Dict{String,Any},Bool}}

Each documented body field of `e` as `(name, schema, required)`, with the
endpoint's `fields` keywords merged into its schema. A body that is not an
object is one field named `body`.
"""
function body_fields(e::Endpoint)
    e.body === nothing && return Tuple{String,Dict{String,Any},Bool}[]
    T = e.body
    is_object_struct(T) || return [("body", schema(T), e.body_required)]
    s = schema(T)
    required = Set{String}(get(s, "required", String[]))
    union!(required, e.required)
    out = Tuple{String,Dict{String,Any},Bool}[]
    for name in json_fields(T)
        prop = with_fields(s["properties"][name], get(e.fields, name, nothing))
        # A required field's default only fills in a value the server rejects,
        # and a null default just means "left out", so neither helps a caller.
        (name in required || get(prop, "default", missing) === nothing) && delete!(prop, "default")
        name in required && get(prop, "type", nothing) == "string" && get!(prop, "minLength", 1)
        push!(out, (name, prop, name in required))
    end
    return out
end

"A copy of schema `s` with an endpoint's `fields` keywords for it, if any."
function with_fields(s::Dict{String,Any}, extra)
    out = copy(s)
    extra === nothing && return out
    for (k, v) in extra
        out[k] = v isa Tuple ? collect(v) : v
    end
    return out
end

"""
    mcp_tools(endpoints = ENDPOINTS; service = "", auto_key_note = "") -> Vector{McpTool}

The MCP tools for every official endpoint documented with [`tool`](@ref), in
documentation order.

- `service`: the name of the system the tools change, used in "This changes
  `service` data." Left empty, the sentence is "This changes data."
- `auto_key_note`: a sentence added to the description of each tool's `auto_key`
  argument, telling agents what the MCP server does when they leave it out,
  such as how long a repeated call reuses the key.
"""
function mcp_tools(endpoints::Vector{Endpoint} = ENDPOINTS; service::AbstractString = "",
                   auto_key_note::AbstractString = "")
    tools = McpTool[]
    for e in endpoints
        is_tool(e) || continue
        t = e.mcp::Tool
        args = tool_arguments(e; auto_key_note)
        props = Dict{String,Any}()
        required = String[]
        for a in args
            props[a.name] = a.schema
            a.required && push!(required, a.name)
        end
        input = Dict{String,Any}(
            "type" => "object",
            "properties" => props,
            "additionalProperties" => false,
        )
        isempty(required) || (input["required"] = required)
        read_only = is_read_only(e)
        annotations = Dict{String,Any}(
            "title" => t.title,
            "readOnlyHint" => read_only,
            "openWorldHint" => e.notifies || e.moves_money,
        )
        if !read_only
            annotations["destructiveHint"] = t.destructive
            annotations["idempotentHint"] = something(t.idempotent, e.method in ("PUT", "DELETE"))
        end
        push!(tools, McpTool(t.name, t.title, tool_description(e; service), input, annotations,
            e.method, e.path, args, e.body_required, t.widget === nothing ? "" : String(t.widget),
            t.auto_key, e))
    end
    return tools
end

"""
    tool_description(e; service = "") -> String

The description an agent reads before calling the tool: what it does, who may use
it, what it returns, its effects, and agent guidance.
"""
function tool_description(e::Endpoint; service::AbstractString = "")
    t = e.mcp::Tool
    parts = String[ensure_period(e.summary)]
    isempty(e.description) || push!(parts, e.description)
    push!(parts, "Who can use this: " * ensure_period(e.access))
    isempty(e.returns) || push!(parts, "Returns: " * ensure_period(e.returns))
    effects = effect_lines(e, service)
    isempty(effects) || push!(parts, join(effects, " "))
    isempty(t.guidance) || push!(parts, t.guidance)
    return join(parts, "\n\n")
end

"""
A tool that changes nothing: a GET, or a `preview_` or `validate_` tool, which
only shows what a change would do.
"""
is_read_only(e::Endpoint) = e.method == "GET" ||
    any(prefix -> startswith((e.mcp::Tool).name, prefix), ("preview_", "validate_"))

function effect_lines(e::Endpoint, service::AbstractString)
    t = e.mcp::Tool
    lines = String[]
    if is_read_only(e)
        push!(lines, "Read-only: this changes nothing.")
    else
        push!(lines, isempty(service) ? "This changes data." : "This changes $(service) data.")
    end
    e.notifies && push!(lines, "It sends email or text messages to people, so confirm the recipients and wording with the user first.")
    e.moves_money && push!(lines, "It moves or records money, so confirm the exact amount with the user first.")
    t.destructive && push!(lines, "It deletes, cancels, or overwrites data, so get the user's explicit go-ahead first.")
    return lines
end

ensure_period(text::AbstractString) =
    isempty(text) || endswith(text, ".") || endswith(text, "?") || endswith(text, ")") ? String(text) : string(text, ".")

"""
    tool_definition(tool) -> JSON.Object

The tool as an MCP server lists it in its `tools/list` answer: `name`, `title`,
`description`, `inputSchema` (arguments in [`tool_arguments`](@ref) order), and
`annotations`.
"""
tool_definition(t::McpTool) = ordered(Dict{String,Any}(
    "name" => t.name,
    "title" => t.title,
    "description" => t.description,
    "inputSchema" => ordered(t.input_schema; property_order = [a.name for a in t.arguments]),
    "annotations" => t.annotations,
))
