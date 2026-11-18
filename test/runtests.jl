using Dates, JSON, RouteDocs, Test

RouteDocs.PATH_PARAMS["note_id"] = "Note ID. Get it from `list_notes`."
include("example/api.jl")

const ROUTES = Set([("POST", "/v1/notes"), ("GET", "/v1/notes"), ("GET", "/v1/notes/{note_id}"),
    ("DELETE", "/v1/notes/{note_id}"), ("POST", "/v1/notes/{note_id}/share"), ("GET", "/internal/health")])
const WIDGETS = Set([:note])
const VERBS = (RouteDocs.TOOL_VERBS..., "share")

endpoint(method, path) = only(e for e in RouteDocs.ENDPOINTS if e.method == method && e.path == path)

module Other
using StructUtils
"Another module's note."
@kwarg struct Note
    "Its title."
    title::String
end
end

"Document one more route without keeping it in `ENDPOINTS`."
function scratch_endpoint(route; kw...)
    RouteDocs.endpoint(route; summary = "Scratch route", description = "A scratch route.",
                       access = "Anyone.", returns = "Nothing much.", kw...)
    return pop!(RouteDocs.ENDPOINTS)
end

@testset "RouteDocs" begin

@testset "documenting routes" begin
    @test [g.slug for g in RouteDocs.GROUPS] == ["notes", "internal"]
    @test RouteDocs.GROUPS[1].description == "Short notes that people write and share. Each note has a color."
    @test length(RouteDocs.ENDPOINTS) == 6
    e = endpoint("GET", "/v1/notes/{note_id}")
    @test e.group == "notes"
    @test only(e.path_params).description == "Note ID. Get it from `list_notes`."
    @test occursin(r"^example[/\\]api\.jl:\d+$", e.source)
    @test_throws ArgumentError RouteDocs.endpoint("/v1/notes"; summary = "No method")
    @test_throws ArgumentError RouteDocs.endpoint("FETCH /v1/notes"; summary = "Unknown method")
    @test_throws ArgumentError RouteDocs.endpoint("GET /v1/notes"; summary = "Bad param", params = (user_id = "User ID.",))
    @test_throws ArgumentError RouteDocs.group("notes"; label = "Notes", description = "Again.")
    @test length(RouteDocs.ENDPOINTS) == 6
end

@testset "strip_text" begin
    @test RouteDocs.strip_text("\nOne line\ngoes on.\n\nNext paragraph.\n") == "One line goes on.\n\nNext paragraph."
    @test RouteDocs.strip_text("Steps:\n- first\n- second") == "Steps:\n- first\n- second"
end

@testset "problems" begin
    @test RouteDocs.problems(; routes = ROUTES, widgets = WIDGETS, verbs = VERBS) == String[]
    issues = RouteDocs.problems(; routes = push!(copy(ROUTES), ("GET", "/v1/tags")))
    @test "GET /v1/tags is registered but not documented" in issues
    @test any(i -> occursin("uses widget note, which the MCP server does not define", i), issues)
    @test any(i -> occursin("tool name share_note should start with a verb", i), issues)

    RouteDocs.endpoint("GET /v1/notes/{note_id}/history";
        summary = "Read a note's history.",
        description = "Like `get_notes`, with every earlier version.",
        mcp = RouteDocs.tool("get_note_history"; title = ""))
    bad = pop!(RouteDocs.ENDPOINTS)
    issues = RouteDocs.problems(; routes = ROUTES, widgets = WIDGETS, verbs = VERBS,
                                endpoints = [RouteDocs.ENDPOINTS; bad])
    where_ = "GET /v1/notes/{note_id}/history ($(bad.source))"
    @test "$(where_) is documented but no such route is registered" in issues
    @test "$(where_) summary should not end with a period" in issues
    @test "$(where_) needs `access` (who can use it)" in issues
    @test "$(where_) needs `returns`" in issues
    @test "$(where_) tool needs a title" in issues
    @test "$(where_) mentions `get_notes`, which is not an MCP tool" in issues
end

@testset "OpenAPI" begin
    security(e) = e.path == "/v1/notes" && e.method == "GET" ? Any[] : Any[Dict("token" => String[])]
    error_schema = Dict{String,Any}("type" => "object", "properties" => Dict{String,Any}(
        "message" => Dict{String,Any}("type" => "string")))
    doc = RouteDocs.openapi(; title = "Notes API", version = "1.2.0", description = "Notes.",
        servers = ["https://api.example.com"],
        security_schemes = Dict{String,Any}("token" => Dict{String,Any}("type" => "http", "scheme" => "bearer")),
        security, error_schema)
    @test collect(keys(doc))[1:3] == ["openapi", "info", "servers"]
    @test doc["openapi"] == "3.1.0"
    @test doc["info"]["title"] == "Notes API" && doc["info"]["version"] == "1.2.0"
    @test doc["servers"] == [Dict("url" => "https://api.example.com")]
    @test sort(collect(keys(doc["paths"]))) == ["/v1/notes", "/v1/notes/{note_id}", "/v1/notes/{note_id}/share"]
    @test [t["name"] for t in doc["tags"]] == ["notes"]

    create = doc["paths"]["/v1/notes"]["post"]
    @test create["operationId"] == "create_note"
    @test create["x-mcp-tool"] == "create_note"
    @test create["security"] == [Dict("token" => String[])]
    body = create["requestBody"]["content"]["application/json"]["schema"]
    @test body["required"] == ["text"]
    @test body["properties"]["color"]["enum"] == ["yellow", "blue"]
    @test body["properties"]["text"]["description"] == "What the note says."
    @test create["responses"]["201"]["content"]["application/json"]["schema"] ==
        Dict("\$ref" => "#/components/schemas/NoteResponse")
    @test create["responses"]["400"]["content"]["application/json"]["schema"] ==
        Dict("\$ref" => "#/components/schemas/Error")
    @test doc["paths"]["/v1/notes"]["get"]["security"] == []
    @test !haskey(doc["paths"]["/v1/notes/{note_id}"]["delete"]["responses"]["204"], "content")
    @test doc["paths"]["/v1/notes/{note_id}/share"]["post"]["x-sends-notifications"] == true

    schemas = doc["components"]["schemas"]
    @test schemas["Error"] == error_schema
    @test schemas["Note"]["description"] == "A note."
    @test schemas["Note"]["required"] == ["id", "text", "created_at"]
    @test schemas["Note"]["properties"]["created_at"]["format"] == "date-time"
    @test schemas["Note"]["properties"]["color"]["type"] == ["string", "null"]
    @test doc["components"]["securitySchemes"]["token"]["scheme"] == "bearer"
    @test JSON.parse(JSON.json(doc)) == JSON.parse(JSON.json(doc; pretty = 2))

    plain = RouteDocs.openapi(; title = "Notes API", version = "1")
    @test !haskey(plain, "servers")
    @test !haskey(plain["components"]["schemas"], "Error")
    @test !haskey(plain["paths"]["/v1/notes"]["post"], "security")
    @test !haskey(plain["paths"]["/v1/notes"]["post"]["responses"]["400"], "content")
end

@testset "MCP tools" begin
    tools = RouteDocs.mcp_tools(; service = "Notes", auto_key_note = "Leave it out and the server picks one.")
    @test [t.name for t in tools] == ["create_note", "list_notes", "get_note", "delete_note", "share_note"]
    byname = Dict(t.name => t for t in tools)

    create = byname["create_note"]
    @test [(a.name, a.location, a.required) for a in create.arguments] ==
        [("text", :body, true), ("color", :body, false), ("request_key", :body, false)]
    @test create.input_schema["required"] == ["text"]
    @test create.input_schema["additionalProperties"] == false
    @test create.input_schema["properties"]["text"]["minLength"] == 1
    @test create.input_schema["properties"]["request_key"]["description"] ==
        "A key that makes a repeated request create the note once. Leave it out and the server picks one."
    @test create.annotations == Dict("title" => "Write a note", "readOnlyHint" => false,
        "openWorldHint" => false, "destructiveHint" => false, "idempotentHint" => false)
    @test create.auto_key == "request_key" && create.widget == "note"
    @test occursin("\n\nThis changes Notes data.", create.description)
    @test startswith(create.description, "Write a note.\n\nSaves a new note.")
    @test occursin("Who can use this: Any signed-in user.", create.description)

    list = byname["list_notes"]
    @test list.input_schema["properties"]["limit"]["default"] == 20
    @test list.input_schema["properties"]["tag"]["type"] == "array"
    @test list.annotations["readOnlyHint"] == true
    @test occursin("Read-only: this changes nothing.", list.description)

    @test byname["get_note"].arguments[1].schema["description"] == "Note ID. Get it from `list_notes`."
    delete = byname["delete_note"]
    @test delete.annotations["destructiveHint"] == true && delete.annotations["idempotentHint"] == true
    @test occursin("get the user's explicit go-ahead first", delete.description)

    share = byname["share_note"]
    @test [(a.name, a.location, a.target) for a in share.arguments] ==
        [("note_id", :path, "note_id"), ("email", :body, "email"), ("into_note_id", :body, "note_id")]
    @test share.annotations["openWorldHint"] == true
    @test endswith(share.description, "Confirm the address with the user first.")

    definition = RouteDocs.tool_definition(share)
    @test sort(collect(keys(definition))) == ["annotations", "description", "inputSchema", "name", "title"]
    @test collect(keys(definition["inputSchema"]["properties"])) == ["note_id", "email", "into_note_id"]
    @test occursin("This changes data.", only(t for t in RouteDocs.mcp_tools() if t.name == "share_note").description)
end

@testset "shapes and examples" begin
    @test RouteDocs.shape_text(Example.CreateNoteRequest) ==
        "{ text?: string; color?: string | null; request_key?: string }"
    @test RouteDocs.shape_text(Example.NoteListResponse) == "{ notes?: Note[] }"
    @test RouteDocs.example_value(RouteDocs.schema(Example.Note)) ==
        Dict("id" => "string", "text" => "string", "created_at" => "2026-11-07T18:30:00Z")
end

@testset "contract_problems" begin
    ok = RouteDocs.contract_problems(;
        bodies = [("POST", "/v1/notes", Example.CreateNoteRequest)],
        responses = [("GET", "/v1/notes/{note_id}", Example.NoteResponse)],
        query_params = [("GET", "/v1/notes", "limit")])
    @test ok == String[]
    issues = RouteDocs.contract_problems(;
        bodies = [("POST", "/v1/notes", Example.ShareNoteRequest), ("GET", "/v1/notes", Example.Note)],
        responses = [("GET", "/v1/notes/{note_id}", Example.NoteListResponse)],
        query_params = [("GET", "/v1/notes", "page")])
    @test length(issues) == 4
    @test any(i -> occursin("parses Main.Example.ShareNoteRequest but documents body", i), issues)
    @test any(i -> occursin("parses a Main.Example.Note body but documents none", i), issues)
    @test any(i -> occursin("returns Main.Example.NoteListResponse but documents response", i), issues)
    @test any(i -> occursin("reads query parameter `page`, which is not documented", i), issues)
end

@testset "edge cases" begin
    @test RouteDocs.path_param_names("/v1/users/{userId}/items/{item_id2}") == ["userId", "item_id2"]
    @test RouteDocs.ordered(Dict(:count => 1, :name => "a")) == Dict("count" => 1, "name" => "a")
    @test RouteDocs.schema(Base.UUID) == Dict("type" => "string", "format" => "uuid")
    @test Set(s["type"] for s in RouteDocs.schema(Union{Int,Missing})["anyOf"]) == Set(["integer", "null"])
    pair = RouteDocs.schema(Tuple{Int,String})
    @test pair["minItems"] == 2 && pair["maxItems"] == 2
    @test RouteDocs.example_value(pair) == [0, "string"]

    tags = scratch_endpoint("PUT /v1/notes/{note_id}/tags"; body = Set{String},
        fields = (body = (description = "The note's tags.",),),
        mcp = RouteDocs.tool("set_note_tags"; title = "Set a note's tags"))
    (name, s, required) = only(RouteDocs.body_fields(tags))
    @test name == "body" && s["uniqueItems"] && s["description"] == "The note's tags." && required
    @test isempty(RouteDocs.problems(; routes = push!(copy(ROUTES), (tags.method, tags.path)), widgets = WIDGETS,
                                     verbs = VERBS, endpoints = [RouteDocs.ENDPOINTS; tags]))

    long = scratch_endpoint("POST /v1/notes/long"; body = Example.CreateNoteRequest, required = ["text"],
        fields = (text = (minLength = 3,),),
        query = [RouteDocs.param("page_size", Int; description = "Notes per page.", required = true)],
        mcp = RouteDocs.tool("create_long_note"; title = "Write a long note", defaults = (page_size = 10,)))
    tool = only(RouteDocs.mcp_tools([long]))
    @test tool.input_schema["properties"]["text"]["minLength"] == 3
    @test tool.input_schema["required"] == ["text"]

    clash = scratch_endpoint("GET /v1/other-notes"; response = Other.Note, mcp = RouteDocs.excluded("Only for the web app."))
    twin = scratch_endpoint("GET /v1/other_notes"; mcp = RouteDocs.excluded("Only for the web app."))
    issues = RouteDocs.problems(; routes = Set([("GET", "/v1/other-notes"), ("GET", "/v1/other_notes"), ROUTES...]),
                                widgets = WIDGETS, verbs = VERBS, endpoints = [RouteDocs.ENDPOINTS; clash; twin])
    @test any(i -> startswith(i, "OpenAPI schema name Note would stand for more than one type"), issues)
    @test "GET /v1/other_notes has the same OpenAPI operationId, get_v1_other_notes, as GET /v1/other-notes" in issues

    @test RouteDocs.schema(Union{Nothing,Missing}) == Dict("type" => "null")
    count_only = scratch_endpoint("GET /v1/notes/count"; response = Integer, mcp = RouteDocs.excluded("Only for the web app."))
    @test length(RouteDocs.contract_problems(; bodies = [], query_params = [],
        responses = [("GET", "/v1/notes/count", Bool)], endpoints = [count_only])) == 1
    @test isempty(RouteDocs.contract_problems(; bodies = [], query_params = [],
        responses = [("GET", "/v1/notes/count", Int)], endpoints = [count_only]))
    pair_only = scratch_endpoint("GET /v1/notes/pair"; response = Tuple{Integer}, mcp = RouteDocs.excluded("Only for the web app."))
    @test length(RouteDocs.contract_problems(; bodies = [], query_params = [],
        responses = [("GET", "/v1/notes/pair", Tuple{Bool})], endpoints = [pair_only])) == 1
    loose = scratch_endpoint("GET /v1/notes/loose"; response = Vector, mcp = RouteDocs.excluded("Only for the web app."))
    @test isempty(RouteDocs.contract_problems(; bodies = [], query_params = [],
        responses = [("GET", "/v1/notes/loose", Vector{Int})], endpoints = [loose]))
    anything = scratch_endpoint("POST /v1/notes/anything"; body = Any, response = Real, mcp = RouteDocs.excluded("Only for the web app."))
    @test isempty(RouteDocs.contract_problems(; query_params = [], endpoints = [anything],
        bodies = [("POST", "/v1/notes/anything", Int)], responses = [("POST", "/v1/notes/anything", Float64)]))
    named = scratch_endpoint("POST /v1/notes/named"; body = Dict{String,String}, required = ["name"],
        mcp = RouteDocs.excluded("Only for the web app."))
    doc = RouteDocs.openapi([named]; title = "Notes API", version = "1")
    @test doc["paths"]["/v1/notes/named"]["post"]["requestBody"]["content"]["application/json"]["schema"]["required"] == ["name"]

    maybe = scratch_endpoint("GET /v1/notes/maybe"; response = Union{Example.Note,Nothing}, mcp = RouteDocs.excluded("Only for the web app."))
    @test isempty(RouteDocs.contract_problems(; bodies = [], query_params = [],
        responses = [("GET", "/v1/notes/maybe", Nothing), ("GET", "/v1/notes/maybe", Example.Note)], endpoints = [maybe]))
end

@testset "reset!" begin
    RouteDocs.reset!()
    @test isempty(RouteDocs.ENDPOINTS) && isempty(RouteDocs.GROUPS)
    @test_throws ArgumentError RouteDocs.endpoint("GET /v1/notes"; summary = "No group yet")
end

end
