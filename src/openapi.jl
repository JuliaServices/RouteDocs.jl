const KEY_ORDER = ["openapi", "info", "servers", "id", "operationId", "method", "path",
    "group", "groupLabel", "summary", "description", "tags", "paths", "components",
    "type", "format", "title", "properties",
    "required", "items", "enum", "default", "examples", "example", "additionalProperties",
    "name", "in", "schema", "parameters", "requestBody", "responses", "security"]

"""
    ordered(x; property_order = nothing) -> value with deterministic key order

Recursively copy `x`, turning dictionaries into insertion-ordered JSON objects
whose keys follow `KEY_ORDER` and then sort alphabetically, so generated files
diff cleanly. `properties` of an object schema keep `property_order` when given.
"""
function ordered(@nospecialize(x); property_order::Union{Nothing,Vector{String}} = nothing)
    x isa JSON.Object && return x  # already ordered
    if x isa AbstractDict
        keys_sorted = sort!(String[String(k) for k in keys(x)]; by = k -> (something(findfirst(==(k), KEY_ORDER), length(KEY_ORDER) + 1), k))
        out = JSON.Object{String,Any}()
        for k in keys_sorted
            v = x[k]
            if k == "properties" && property_order !== nothing && v isa AbstractDict
                props = JSON.Object{String,Any}()
                for name in property_order
                    haskey(v, name) && (props[name] = ordered(v[name]))
                end
                for name in sort!(String[String(n) for n in keys(v)])
                    haskey(props, name) || (props[name] = ordered(v[name]))
                end
                out[k] = props
            else
                out[k] = ordered(v)
            end
        end
        return out
    elseif x isa AbstractVector || x isa Tuple
        return Any[ordered(v) for v in x]
    end
    return x
end

"The OpenAPI `operationId` of `e`: its MCP tool name, or one made from its method and path."
function operation_id(e::Endpoint)
    e.mcp isa Tool && return (e.mcp::Tool).name
    slug = replace(lowercase(e.path), r"[{}]" => "", r"[^a-z0-9]+" => "_")
    return string(lowercase(e.method), "_", strip(slug, '_'))
end

"""
    openapi(endpoints = ENDPOINTS; title, version, description = "", servers = [],
            security_schemes = Dict(), security = e -> nothing, error_schema = nothing) -> JSON.Object

The OpenAPI 3.1 document for every official endpoint, with keys in a fixed order
so the written file diffs cleanly.

- `title`, `version`, `description`: the document's `info`.
- `servers`: base URLs of the API.
- `security_schemes`: `components.securitySchemes`, such as
  `Dict("apiToken" => Dict("type" => "apiKey", "in" => "header", "name" => "X-Api-Key"))`.
- `security`: a function of an [`Endpoint`](@ref) that returns its operation's
  `security` list, such as `[Dict("apiToken" => String[])]`, `[]` for a route that
  needs no credential, or `nothing` to leave the key out.
- `error_schema`: the JSON Schema of every error response body, added as
  `components.schemas.Error` and referenced by each endpoint's `errors`. Left
  out, error responses have a description only.

Each operation also carries `x-mcp-tool` (its tool name) or `x-mcp-excluded`
(the reason it has none), and `x-sends-notifications` and `x-moves-money` when
the endpoint documents those effects.
"""
function openapi(endpoints::Vector{Endpoint} = ENDPOINTS; title::AbstractString,
                 version::AbstractString, description::AbstractString = "",
                 servers = String[], security_schemes = Dict{String,Any}(),
                 security = e -> nothing, error_schema = nothing)
    refs = Dict{String,Any}()
    paths = Dict{String,Any}()
    used_groups = Set{String}()
    for e in endpoints
        e.audience === :official || continue
        push!(used_groups, e.group)
        op = Dict{String,Any}(
            "operationId" => operation_id(e),
            "summary" => e.summary,
            "description" => join(filter(!isempty, [e.description, "**Who can use this:** " * e.access]), "\n\n"),
            "tags" => [e.group],
        )
        params = Any[]
        for p in e.path_params
            push!(params, Dict{String,Any}("name" => p.name, "in" => "path", "required" => true,
                "description" => p.description, "schema" => Dict{String,Any}("type" => "string")))
        end
        for p in e.query
            s = param_schema(p)
            delete!(s, "description")
            push!(params, Dict{String,Any}("name" => p.name, "in" => "query", "required" => p.required,
                "description" => p.description, "schema" => s))
        end
        isempty(params) || (op["parameters"] = params)
        if e.body !== nothing
            body_schema = schema(e.body; refs)
            if !isempty(e.required) || !isempty(e.fields)
                # Endpoint-level rules refine the shared struct schema for this operation.
                inline = schema(e.body)
                req = Set{String}(get(inline, "required", String[]))
                union!(req, e.required)
                isempty(req) || (inline["required"] = sort!(collect(req)))
                for (name, extra) in e.fields
                    merge!(inline["properties"][name], Dict{String,Any}(k => (v isa Tuple ? collect(v) : v) for (k, v) in extra))
                end
                body_schema = inline
            end
            op["requestBody"] = Dict{String,Any}("required" => e.body_required,
                "content" => Dict{String,Any}("application/json" => Dict{String,Any}("schema" => body_schema)))
        end
        success = Dict{String,Any}("description" => isempty(e.returns) ? "Success." : e.returns)
        if e.status != 204
            s = e.response === nothing ? Dict{String,Any}() : schema(e.response; refs)
            success["content"] = Dict{String,Any}(e.content_type => Dict{String,Any}("schema" => s))
        end
        responses = Dict{String,Any}(string(e.status) => success)
        for (status, text) in e.errors
            r = Dict{String,Any}("description" => text)
            error_schema === nothing || (r["content"] = Dict{String,Any}("application/json" => Dict{String,Any}(
                "schema" => Dict{String,Any}("\$ref" => "#/components/schemas/Error"))))
            responses[string(status)] = r
        end
        op["responses"] = responses
        requirements = security(e)
        requirements === nothing || (op["security"] = requirements)
        if e.mcp isa Tool
            op["x-mcp-tool"] = (e.mcp::Tool).name
        else
            op["x-mcp-excluded"] = (e.mcp::Exclusion).reason
        end
        e.notifies && (op["x-sends-notifications"] = true)
        e.moves_money && (op["x-moves-money"] = true)
        get!(paths, e.path, Dict{String,Any}())[lowercase(e.method)] = op
    end
    error_schema === nothing || (refs["Error"] = error_schema)
    tags = Any[Dict{String,Any}("name" => g.slug, "x-displayName" => g.label, "description" => g.description)
               for g in GROUPS if g.slug in used_groups]
    info = Dict{String,Any}("title" => String(title), "version" => String(version))
    isempty(description) || (info["description"] = String(description))
    components = Dict{String,Any}("schemas" => refs)
    isempty(security_schemes) || (components["securitySchemes"] = security_schemes)
    doc = Dict{String,Any}("openapi" => "3.1.0", "info" => info, "tags" => tags,
                           "paths" => paths, "components" => components)
    isempty(servers) || (doc["servers"] = Any[Dict{String,Any}("url" => String(url)) for url in servers])
    return ordered(doc)
end
