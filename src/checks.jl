const TOOL_NAME = r"^[a-z][a-z0-9_]{2,63}$"
"""
The verbs a tool name may start with, as in `list_events` or `refund_payment`.
Pass your own to [`problems`](@ref) as `verbs` to allow others.
"""
const TOOL_VERBS = ("list", "get", "create", "update", "delete", "set", "add", "remove",
    "cancel", "send", "record", "publish", "generate", "preview", "search", "find", "check",
    "approve", "deny", "promote", "refund", "invite", "resend", "revoke", "accept", "decline",
    "report", "clear", "assign", "move", "copy", "clone", "archive", "disconnect", "restore", "start", "finish",
    "complete", "reopen", "import", "export", "validate", "seed", "swap", "undo", "transfer",
    "submit", "save", "lock", "unlock", "close", "open", "register", "join", "leave", "claim",
    "resolve", "keep", "rename", "connect", "refresh", "subscribe", "unsubscribe", "message",
    "reply", "score", "adjudicate", "finalize", "pair", "shorten", "repair", "draft", "pick",
    "evaluate", "select", "book", "check_in", "mark", "remind", "review", "attach", "detach",
    "duplicate", "reorder", "upsert", "confirm", "request", "respond", "summarize", "show",
    "rotate", "apply", "sync", "override", "split", "rejoin")

"""
    problems(; routes, widgets = Set{Symbol}(), endpoints = ENDPOINTS, verbs = TOOL_VERBS) -> Vector{String}

Every reason the API documentation is incomplete or inconsistent. `routes` is the
set of `(method, path)` pairs the server registers, with paths written as they
are documented (`/v1/notes/{note_id}`); `widgets` is the set of display widget
names the MCP server can render. A tool name must start with one of `verbs` and
an underscore, and a backticked name that does is taken to refer to a tool. An
empty result means the OpenAPI document and the MCP tools are complete.
"""
function problems(; routes::Set{Tuple{String,String}}, widgets::Set{Symbol} = Set{Symbol}(),
                  endpoints::Vector{Endpoint} = ENDPOINTS, verbs = TOOL_VERBS)
    out = String[]
    seen = Dict{Tuple{String,String},String}()
    for e in endpoints
        key = (e.method, e.path)
        where_ = "$(e.method) $(e.path) ($(e.source))"
        if haskey(seen, key)
            push!(out, "$(where_) is documented twice (also at $(seen[key]))")
        else
            seen[key] = e.source
        end
        key in routes || push!(out, "$(where_) is documented but no such route is registered")
        isempty(e.summary) && push!(out, "$(where_) needs a summary")
        e.audience === :official && append!(out, official_problems(e, where_, widgets, verbs))
    end
    ids = Dict{String,String}()
    for e in endpoints
        e.audience === :official || continue
        id = operation_id(e)
        haskey(ids, id) && push!(out, "$(e.method) $(e.path) has the same OpenAPI operationId, $(id), as $(ids[id])")
        ids[id] = "$(e.method) $(e.path)"
    end
    for (name, types) in sort!(collect(schema_names(endpoints)); by = first)
        length(types) > 1 && push!(out, "OpenAPI schema name $(name) would stand for more than one type: " *
            join(sort!(string.(collect(types))), ", ") * "; rename all but one")
    end
    for route in sort!(collect(routes))
        haskey(seen, route) || push!(out, "$(route[1]) $(route[2]) is registered but not documented")
    end
    tools = Dict{String,String}()
    for e in endpoints
        is_tool(e) || continue
        name = (e.mcp::Tool).name
        haskey(tools, name) && push!(out, "MCP tool name $(name) is used by both $(tools[name]) and $(e.method) $(e.path)")
        tools[name] = "$(e.method) $(e.path)"
    end
    fields = known_field_names(endpoints)
    for e in endpoints
        e.audience === :official || continue
        texts = [e.description, e.access, e.returns]
        e.mcp isa Tool && push!(texts, (e.mcp::Tool).guidance)
        e.mcp isa Exclusion && push!(texts, (e.mcp::Exclusion).reason)
        for text in texts, ref in tool_references(text, verbs)
            haskey(tools, ref) || ref in fields ||
                push!(out, "$(e.method) $(e.path) ($(e.source)) mentions `$(ref)`, which is not an MCP tool")
        end
    end
    for (name, text) in PATH_PARAMS, ref in tool_references(text, verbs)
        haskey(tools, ref) || ref in fields ||
            push!(out, "RouteDocs.PATH_PARAMS[$(repr(name))] mentions `$(ref)`, which is not an MCP tool")
    end
    return out
end

function official_problems(e::Endpoint, where_::String, widgets::Set{Symbol}, verbs)
    out = String[]
    length(e.summary) > 90 && push!(out, "$(where_) summary is longer than 90 characters")
    endswith(e.summary, ".") && push!(out, "$(where_) summary should not end with a period")
    isempty(e.description) && push!(out, "$(where_) needs a description")
    isempty(e.access) && push!(out, "$(where_) needs `access` (who can use it)")
    isempty(e.returns) && e.status != 204 && push!(out, "$(where_) needs `returns`")
    for p in e.path_params
        isempty(p.description) && push!(out, "$(where_) path parameter $(p.name) needs a description (add it to RouteDocs.PATH_PARAMS or `params`)")
    end
    for p in e.query
        isempty(p.description) && push!(out, "$(where_) query parameter $(p.name) needs a description")
    end
    if e.body !== nothing && !is_object_struct(e.body)
        for name in keys(e.fields)
            name == "body" || push!(out, "$(where_) adds schema keywords to $(name), but its body is not an object; use `body`")
        end
    end
    if e.body !== nothing && is_object_struct(e.body)
        names = json_fields(e.body)
        docs = field_docs(e.body)
        for name in names
            haskey(docs, Symbol(name)) || push!(out, "$(where_) body field $(e.body).$(name) needs a docstring")
        end
        for name in e.required
            name in names || push!(out, "$(where_) lists required field $(name), which $(e.body) does not have")
        end
        for name in keys(e.fields)
            name in names || push!(out, "$(where_) adds schema keywords to $(name), which $(e.body) does not have")
        end
    end
    if e.mcp isa Exclusion
        length((e.mcp::Exclusion).reason) < 10 && push!(out, "$(where_) needs an MCP tool or an `excluded` reason")
        return out
    end
    t = e.mcp::Tool
    occursin(TOOL_NAME, t.name) || push!(out, "$(where_) tool name $(t.name) must be snake_case, 3-64 characters")
    any(v -> startswith(t.name, v * "_"), verbs) ||
        push!(out, "$(where_) tool name $(t.name) should start with a verb such as list_, get_, create_, or update_")
    isempty(t.title) && push!(out, "$(where_) tool needs a title")
    t.widget === nothing || t.widget in widgets || push!(out, "$(where_) uses widget $(t.widget), which the MCP server does not define")
    if e.body !== nothing && is_object_struct(e.body)
        fields = json_fields(e.body)
        for name in t.omit
            name in fields || push!(out, "$(where_) omits $(name), which $(e.body) does not have")
        end
        isempty(t.auto_key) || t.auto_key in fields ||
            push!(out, "$(where_) auto_key $(t.auto_key) is not a field of $(e.body)")
    end
    for name in keys(t.defaults)
        any(p -> p.name == name, e.query) || push!(out, "$(where_) has a default for $(name), which is not one of its query parameters")
    end
    names = Dict{String,Symbol}()
    for a in tool_arguments(e)
        if haskey(names, a.name)
            push!(out, "$(where_) tool argument $(a.name) comes from both the $(names[a.name]) and the $(a.location); rename the body field with `rename`")
        else
            names[a.name] = a.location
        end
        desc = get(a.schema, "description", "")
        isempty(desc) && push!(out, "$(where_) tool argument $(a.name) has no description")
    end
    return out
end

"""
The struct types each OpenAPI schema name would stand for, from the bodies and
responses of official endpoints. A name is a struct's name without its module
or type parameters, so two types that share one cannot both be documented.
"""
function schema_names(endpoints::Vector{Endpoint})
    names = Dict{String,Set{Any}}()
    seen = Set{Any}()
    visit(@nospecialize(T)) = begin
        T isa Union && return foreach(visit, Base.uniontypes(T))
        (T isa DataType && !(T in seen)) || return
        push!(seen, T)
        if T <: AbstractVector || T <: AbstractSet
            visit(eltype(T))
        elseif T <: AbstractDict
            visit(valtype(T))
        elseif T <: Tuple || T <: NamedTuple
            foreach(visit, fieldtypes(T))
        elseif is_object_struct(T)
            push!(get!(Set{Any}, names, string(nameof(T))), T)
            foreach(visit, fieldtypes(T))
        end
    end
    for e in endpoints
        e.audience === :official || continue
        e.body === nothing || visit(e.body)
        e.response === nothing || visit(e.response)
    end
    return names
end

"Every parameter and body or response field name, so a backticked field is not mistaken for a tool."
function known_field_names(endpoints::Vector{Endpoint})
    names = Set{String}()
    seen = Set{Any}()
    collect_fields!(T) = begin
        T = nonnothing(T)
        (T isa DataType && !(T in seen)) || return
        push!(seen, T)
        if T <: AbstractVector
            collect_fields!(eltype(T))
        elseif is_object_struct(T) || T <: NamedTuple
            for (n, FT) in zip(fieldnames(T), fieldtypes(T))
                push!(names, String(n))
                collect_fields!(FT)
            end
        end
    end
    for e in endpoints
        foreach(p -> push!(names, p.name), e.path_params)
        foreach(p -> push!(names, p.name), e.query)
        e.body === nothing || collect_fields!(e.body)
        e.response === nothing || collect_fields!(e.response)
    end
    return names
end

"""
Names in backticks that look like MCP tool names (`verb_object`). Every one must
be a real tool so cross-references in the documentation stay correct.
"""
function tool_references(text::AbstractString, verbs)
    refs = String[]
    for m in eachmatch(r"`([a-z][a-z0-9_]+)`", text)
        name = String(m.captures[1])
        occursin('_', name) || continue
        any(v -> startswith(name, v * "_"), verbs) || continue
        push!(refs, name)
    end
    return refs
end

"""
    contract_problems(; bodies, responses, query_params, endpoints) -> Vector{String}

Compare what routes really did during a test run with their documentation.
`bodies` and `responses` are `(method, pattern, type)` records of the request
types routes parsed and the response types they returned; `query_params` are
`(method, pattern, name)` records of the query parameters they read, with each
`pattern` written as the endpoint documents its path. A route that parses a
different body type than its `body`, returns a type whose JSON differs from its
`response`, or reads an undocumented query parameter is a problem.
"""
function contract_problems(; bodies, responses, query_params,
                           endpoints::Vector{Endpoint} = ENDPOINTS)
    by_route = Dict{Tuple{String,String},Endpoint}((e.method, e.path) => e for e in endpoints)
    out = Set{String}()
    for (method, pattern, T) in bodies
        e = get(by_route, (method, pattern), nothing)
        e === nothing && continue
        where_ = "$(method) $(e.path) ($(e.source))"
        if e.body === nothing
            push!(out, "$(where_) parses a $(T) body but documents none")
        elseif !admits(e.body, T)
            push!(out, "$(where_) parses $(T) but documents body = $(e.body)")
        end
    end
    for (method, pattern, T) in responses
        e = get(by_route, (method, pattern), nothing)
        (e === nothing || e.response === nothing) && continue
        admits(e.response, T) ||
            push!(out, "$(method) $(e.path) ($(e.source)) returns $(T) but documents response = $(e.response)")
    end
    for (method, pattern, name) in query_params
        e = get(by_route, (method, pattern), nothing)
        e === nothing && continue
        any(p -> p.name == name, e.query) ||
            push!(out, "$(method) $(e.path) ($(e.source)) reads query parameter `$(name)`, which is not documented")
    end
    return sort!(collect(out))
end

"""
Whether a value of type `T` matches documented type `D` in JSON: the same type,
the same JSON shape, or one member of a documented union.
"""
admits(@nospecialize(D), @nospecialize(T)) = D === T || json_shape(D) == json_shape(T) ||
    (D isa Union && any(m -> m === T || json_shape(m) == json_shape(T), Base.uniontypes(D)))

"""
The JSON shape of `T` without descriptions or defaults, and with required
fields in any order, for comparing two types.
"""
function json_shape(@nospecialize(T))
    shape(x) = x isa AbstractDict ? Dict{String,Any}(
            k => (k == "properties" ? Dict{String,Any}(name => shape(p) for (name, p) in v) :
                  k == "required" ? sort(v) : shape(v))
            for (k, v) in x if !(k in ("description", "default"))) :
        x isa AbstractVector ? Any[shape(v) for v in x] : x
    return shape(schema(T; docs = false))
end
