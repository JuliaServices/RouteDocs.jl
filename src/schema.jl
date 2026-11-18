"""
    field_docs(T) -> Dict{Symbol,String}

The docstrings written on the fields of struct `T`.
"""
function field_docs(T::Type)
    out = Dict{Symbol,String}()
    T isa DataType || return out
    mod = parentmodule(T)
    binding = Base.Docs.Binding(mod, nameof(T))
    multidoc = get(Base.Docs.meta(mod), binding, nothing)
    multidoc === nothing && return out
    for docstr in values(multidoc.docs)
        fields = get(docstr.data, :fields, nothing)
        fields isa AbstractDict || continue
        for (name, text) in fields
            out[Symbol(name)] = strip_text(string(text))
        end
    end
    return out
end

"The docstring written on struct `T` itself, or an empty string."
function type_doc(T::Type)
    T isa DataType || return ""
    mod = parentmodule(T)
    multidoc = get(Base.Docs.meta(mod), Base.Docs.Binding(mod, nameof(T)), nothing)
    multidoc === nothing && return ""
    texts = String[]
    for docstr in values(multidoc.docs)
        push!(texts, strip_text(join(string.(docstr.text))))
    end
    return join(filter(!isempty, texts), "\n\n")
end

"The JSON field names of struct `T`, in declaration order."
json_fields(T::Type) = [String(name) for name in fieldnames(T)]

"Field names of struct `T` that have no default and so must be present in JSON."
function fields_without_default(T::Type)
    defaults = StructUtils.fielddefaults(StructUtils.DefaultStyle(), T)
    return [String(name) for name in fieldnames(T) if !haskey(defaults, name)]
end

"Whether `T` is a struct that JSON reads and writes as an object of its fields."
is_object_struct(T) = T isa DataType && isstructtype(T) && !(T <: Number) &&
    !(T <: AbstractString) && !(T <: AbstractArray) && !(T <: AbstractSet) && !(T <: AbstractDict) &&
    !(T <: Dates.TimeType) && !(T <: Enum) && T !== Nothing && T !== Missing && !(T <: Tuple) &&
    !(T <: NamedTuple) && T !== JSON.JSONText && T !== Symbol && T !== Base.UUID

nonnothing(T) = T isa Union ? Base.typesplit(T, Nothing) : T

"""
    schema(T; refs = nothing, docs = true) -> Dict{String,Any}

The JSON Schema of a value of Julia type `T` as JSON.jl reads and writes it.
Struct fields become object properties, under their field names, described by
their field docstrings; a field without a default is required. `Union{T,Nothing}` accepts `null`.
A `DateTime` is documented as `format: date-time`, which includes a time zone
offset, so serialize it with one (JSON.jl writes none by default). With a
`refs` dictionary, named structs are emitted once under `refs` and referenced as
`#/components/schemas/Name` (for OpenAPI); without one they are written inline
(for MCP tool arguments, which many hosts cannot resolve references in).
"""
function schema(@nospecialize(T); refs::Union{Nothing,Dict{String,Any}} = nothing,
                docs::Bool = true, stack::Vector{Any} = Any[])
    T === Any && return Dict{String,Any}()
    (T === Nothing || T === Missing) && return Dict{String,Any}("type" => "null")
    if T isa Union
        inner = nonnothing(T)
        inner isa Union && return Dict{String,Any}("anyOf" => [schema(t; refs, docs, stack) for t in Base.uniontypes(T)])
        s = schema(inner; refs, docs, stack)
        return nullable(s)
    end
    T isa UnionAll && return Dict{String,Any}()
    T <: AbstractString && return Dict{String,Any}("type" => "string")
    T === Symbol && return Dict{String,Any}("type" => "string")
    T === Base.UUID && return Dict{String,Any}("type" => "string", "format" => "uuid")
    T === Bool && return Dict{String,Any}("type" => "boolean")
    T <: Integer && return Dict{String,Any}("type" => "integer")
    T <: Real && return Dict{String,Any}("type" => "number")
    T === Date && return Dict{String,Any}("type" => "string", "format" => "date")
    T === DateTime && return Dict{String,Any}("type" => "string", "format" => "date-time")
    T === Time && return Dict{String,Any}("type" => "string", "pattern" => "^\\d{2}:\\d{2}(:\\d{2})?\$")
    T <: Enum && return Dict{String,Any}("type" => "string", "enum" => [string(x) for x in instances(T)])
    T === JSON.JSONText && return Dict{String,Any}()
    if T <: AbstractVector
        return Dict{String,Any}("type" => "array", "items" => schema(eltype(T); refs, docs, stack))
    end
    if T <: AbstractSet
        return Dict{String,Any}("type" => "array", "uniqueItems" => true, "items" => schema(eltype(T); refs, docs, stack))
    end
    if T <: AbstractDict
        V = valtype(T)
        return V === Any ? Dict{String,Any}("type" => "object") :
            Dict{String,Any}("type" => "object", "additionalProperties" => schema(V; refs, docs, stack))
    end
    if T <: NamedTuple
        props = Dict{String,Any}()
        for (name, FT) in zip(fieldnames(T), fieldtypes(T))
            props[String(name)] = schema(FT; refs, docs, stack)
        end
        return Dict{String,Any}("type" => "object", "properties" => props, "required" => [String(n) for n in fieldnames(T)])
    end
    if T <: Tuple
        n = fieldcount(T)
        return Dict{String,Any}("type" => "array", "prefixItems" => [schema(t; refs, docs, stack) for t in fieldtypes(T)],
                                "minItems" => n, "maxItems" => n)
    end
    is_object_struct(T) || throw(ArgumentError("no JSON Schema mapping for $(T)"))
    if refs !== nothing
        name = string(nameof(T))
        if !haskey(refs, name)
            refs[name] = Dict{String,Any}()  # reserve the name before recursing
            refs[name] = object_schema(T; refs, docs, stack)
        end
        return Dict{String,Any}("\$ref" => "#/components/schemas/$(name)")
    end
    T in stack && return Dict{String,Any}("type" => "object")
    return object_schema(T; refs, docs, stack)
end

function object_schema(T::Type; refs, docs::Bool, stack::Vector{Any})
    push!(stack, T)
    fdocs = docs ? field_docs(T) : Dict{Symbol,String}()
    defaults = StructUtils.fielddefaults(StructUtils.DefaultStyle(), T)
    props = Dict{String,Any}()
    for (name, FT) in zip(fieldnames(T), fieldtypes(T))
        s = schema(FT; refs, docs, stack)
        d = get(fdocs, name, "")
        isempty(d) || (s = with_description(s, d))
        if haskey(defaults, name)
            default = defaults[name]
            json_default(default) === missing || (s = with_default(s, json_default(default)))
        end
        props[String(name)] = s
    end
    pop!(stack)
    out = Dict{String,Any}("type" => "object", "properties" => props)
    required = fields_without_default(T)
    isempty(required) || (out["required"] = required)
    if docs
        doc = type_doc(T)
        isempty(doc) || (out["description"] = doc)
    end
    return out
end

"A schema that also accepts JSON `null`."
function nullable(s::Dict{String,Any})
    t = get(s, "type", nothing)
    t == "null" && return s
    if t isa String && !haskey(s, "\$ref")
        out = copy(s)
        out["type"] = [t, "null"]
        haskey(out, "enum") && (out["enum"] = vcat(out["enum"], [nothing]))
        return out
    end
    return Dict{String,Any}("anyOf" => Any[s, Dict{String,Any}("type" => "null")])
end

function with_description(s::Dict{String,Any}, description::String)
    out = copy(s)
    if haskey(out, "\$ref")
        # Sibling keywords next to a reference are ignored by older readers.
        return Dict{String,Any}("allOf" => Any[out], "description" => description)
    end
    out["description"] = description
    return out
end

function with_default(s::Dict{String,Any}, value)
    out = copy(s)
    out["default"] = value
    return out
end

"The JSON form of a field default, or `missing` when it has none worth showing."
function json_default(@nospecialize(x))
    x === nothing && return nothing
    x isa Union{AbstractString,Bool,Integer,AbstractFloat} && return x
    x isa Enum && return string(x)
    x isa AbstractVector && isempty(x) && return Any[]
    return missing
end

"""
    shape_text(T) -> String

A compact TypeScript-style rendering of `T` for human-readable documentation,
such as `{ name: string; starts_at?: string | null }`.
"""
function shape_text(@nospecialize(T); depth::Int = 0)
    depth > 3 && return "object"
    T === Any && return "unknown"
    (T === Nothing || T === Missing) && return "null"
    T === Base.UUID && return "string"
    if T isa Union
        members = sort(Base.uniontypes(T); by = t -> t === Nothing)  # null last
        return join(unique([shape_text(t; depth) for t in members]), " | ")
    end
    T <: AbstractString && return "string"
    T === Bool && return "boolean"
    T <: Real && return "number"
    T <: Dates.TimeType && return "string"
    T <: Enum && return join(["'$(x)'" for x in instances(T)], " | ")
    T === JSON.JSONText && return "unknown"
    T <: AbstractVector && return string(shape_item(eltype(T); depth), "[]")
    T <: AbstractDict && return "Record<string, $(shape_text(valtype(T); depth = depth + 1))>"
    if T <: NamedTuple
        parts = ["$(n): $(shape_text(FT; depth = depth + 1))" for (n, FT) in zip(fieldnames(T), fieldtypes(T))]
        return string("{ ", join(parts, "; "), " }")
    end
    is_object_struct(T) || return "unknown"
    depth > 0 && return string(nameof(T))
    defaults = StructUtils.fielddefaults(StructUtils.DefaultStyle(), T)
    parts = String[]
    for (n, FT) in zip(fieldnames(T), fieldtypes(T))
        optional = haskey(defaults, n) ? "?" : ""
        push!(parts, "$(n)$(optional): $(shape_text(FT; depth = depth + 1))")
    end
    return string("{ ", join(parts, "; "), " }")
end

function shape_item(@nospecialize(T); depth::Int)
    s = shape_text(T; depth = depth + 1)
    return occursin(' ', s) ? "($(s))" : s
end

"""
    example_value(schema) -> Any

A small example JSON value that satisfies `schema`, built from its examples,
defaults, enums, and formats.
"""
function example_value(s::Dict{String,Any}; refs = nothing, depth::Int = 0)
    haskey(s, "example") && return s["example"]
    haskey(s, "examples") && !isempty(s["examples"]) && return first(s["examples"])
    if haskey(s, "\$ref") && refs !== nothing
        name = last(split(s["\$ref"], '/'))
        return depth > 3 ? Dict{String,Any}() : example_value(refs[name]; refs, depth = depth + 1)
    end
    haskey(s, "allOf") && return example_value(first(s["allOf"]); refs, depth)
    haskey(s, "anyOf") && return example_value(first(s["anyOf"]); refs, depth)
    haskey(s, "enum") && return first(s["enum"])
    t = get(s, "type", nothing)
    t isa Vector && (t = first(filter(!=("null"), t)))
    t == "string" && return get(Dict("date" => "2026-11-07", "date-time" => "2026-11-07T18:30:00Z"),
                                get(s, "format", ""), "string")
    t == "integer" && return 0
    t == "number" && return 0
    t == "boolean" && return false
    t == "array" && haskey(s, "prefixItems") && return Any[example_value(p; refs, depth = depth + 1) for p in s["prefixItems"]]
    t == "array" && return depth > 3 ? Any[] : Any[example_value(get(s, "items", Dict{String,Any}()); refs, depth = depth + 1)]
    if t == "object"
        out = Dict{String,Any}()
        depth > 3 && return out
        for name in get(s, "required", String[])
            out[name] = example_value(s["properties"][name]; refs, depth = depth + 1)
        end
        return out
    end
    return nothing
end
