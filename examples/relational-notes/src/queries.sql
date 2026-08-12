-- name: notesInFolder :live
SELECT n.id, n.title, n.updated_at
FROM note AS n
WHERE n.folder_id = :folder
ORDER BY n.updated_at DESC;

-- name: searchNotes :live
SELECT n.id, n.title, n.updated_at
FROM search_index AS search_index
JOIN note AS n ON n.id = search_index.rowid
WHERE search_index.title MATCH :term
ORDER BY n.updated_at DESC;

-- name: insertFolder :exec
INSERT INTO folder(id, name) VALUES(:id, :name);

-- name: insertNote :exec
INSERT INTO note(id, folder_id, title, updated_at)
VALUES(:id, :folder, :title, :updated);

-- name: insertSearch :exec
INSERT INTO search_index(rowid, title) VALUES(:id, :title);

-- name: insertTag :exec
INSERT INTO tag(id, name) VALUES(:id, :name);

-- name: tagNote :exec
INSERT INTO note_tag(note_id, tag_id) VALUES(:note, :tag);

-- name: moveNote :exec
UPDATE note SET folder_id = :to, updated_at = :updated WHERE id = :id;
