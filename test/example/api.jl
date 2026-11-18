# A small notes API, documented the way an application documents its routes.

module Example

using Dates, StructUtils
import RouteDocs

"A note."
@kwarg struct Note
    "The note's ID."
    id::String
    "What the note says."
    text::String
    "The note's color, or `null` for none."
    color::Union{String,Nothing} = nothing
    "When the note was written, in UTC."
    created_at::DateTime
end

"One note."
@kwarg struct NoteResponse
    "The note."
    note::Note
end

"Notes, newest first."
@kwarg struct NoteListResponse
    "The notes."
    notes::Vector{Note} = Note[]
end

"A new note."
@kwarg struct CreateNoteRequest
    "What the note says."
    text::String = ""
    "The note's color: `yellow` or `blue`. Leave it out for none."
    color::Union{String,Nothing} = nothing
    "A key that makes a repeated request create the note once."
    request_key::String = ""
end

"Who to share a note with."
@kwarg struct ShareNoteRequest
    "The email address to send the note to."
    email::String
    "Add the text to this existing note of theirs instead of a new one."
    note_id::Union{String,Nothing} = nothing
    "The sender's typed name, which only a person may give."
    signature::String = ""
end

RouteDocs.group("notes";
    label = "Notes",
    description = """
        Short notes that people write and share.
        Each note has a color.
        """)

RouteDocs.endpoint("POST /v1/notes";
    summary = "Write a note",
    description = "Saves a new note. Read it back with `get_note`.",
    access = "Any signed-in user.",
    body = CreateNoteRequest,
    required = ["text"],
    fields = (color = (enum = ["yellow", "blue"],),),
    response = NoteResponse,
    status = 201,
    returns = "The new note, including its `id`.",
    errors = [400 => "The text is empty."],
    mcp = RouteDocs.tool("create_note"; title = "Write a note", auto_key = "request_key", widget = :note))

RouteDocs.endpoint("GET /v1/notes";
    summary = "List notes",
    description = "Lists the caller's notes, newest first.",
    access = "Any signed-in user.",
    query = [RouteDocs.param("limit", Int; description = "At most this many notes."),
             RouteDocs.param("tag", Vector{String}; description = "Only notes with every one of these tags.")],
    response = NoteListResponse,
    returns = "`notes`.",
    mcp = RouteDocs.tool("list_notes"; title = "List notes", defaults = (limit = 20,)))

RouteDocs.endpoint("GET /v1/notes/{note_id}";
    summary = "Read a note",
    description = "Returns one note.",
    access = "The note's writer.",
    response = NoteResponse,
    returns = "The note.",
    errors = [404 => "No note has this ID."],
    mcp = RouteDocs.tool("get_note"; title = "Read a note"))

RouteDocs.endpoint("DELETE /v1/notes/{note_id}";
    summary = "Delete a note",
    description = "Deletes the note for good.",
    access = "The note's writer.",
    status = 204,
    mcp = RouteDocs.tool("delete_note"; title = "Delete a note", destructive = true))

RouteDocs.endpoint("POST /v1/notes/{note_id}/share";
    summary = "Share a note",
    description = "Emails the note to someone.",
    access = "The note's writer.",
    body = ShareNoteRequest,
    response = NoteResponse,
    returns = "The shared note.",
    notifies = true,
    mcp = RouteDocs.tool("share_note"; title = "Share a note",
        guidance = "Confirm the address with the user first.",
        rename = (note_id = "into_note_id",), omit = ["signature"]))

RouteDocs.group("internal"; label = "Internal", description = "Routes for the operators.")

RouteDocs.endpoint("GET /internal/health";
    summary = "Check the server",
    audience = :internal,
    mcp = RouteDocs.excluded("A health check for load balancers."))

end
