-- Development bridge only. The GDScript SQLite provider is not installed yet.
-- Apply once in BEGIN IMMEDIATE; never use a destructive fallback for older data.
CREATE TABLE schema_migrations (
    version INTEGER PRIMARY KEY CHECK (version > 0),
    sql_sha256 TEXT NOT NULL CHECK (length(sql_sha256) = 64),
    applied_at_utc TEXT NOT NULL
);

CREATE TABLE local_project (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    generation INTEGER NOT NULL UNIQUE CHECK (generation >= 0),
    data_kind TEXT NOT NULL CHECK (data_kind IN ('personal', 'demo')),
    project_schema_version INTEGER NOT NULL CHECK (project_schema_version >= 1),
    project_sha256 TEXT NOT NULL CHECK (length(project_sha256) = 64),
    project_json TEXT NOT NULL CHECK (length(project_json) > 1),
    updated_at_utc TEXT NOT NULL
);

-- This row is the only content a future wallpaper reader should request.
-- The deferred FK makes a project-only generation update fail at COMMIT.
CREATE TABLE published_display (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    generation INTEGER NOT NULL,
    display_schema_version INTEGER NOT NULL CHECK (display_schema_version >= 1),
    display_sha256 TEXT NOT NULL CHECK (length(display_sha256) = 64),
    display_json TEXT NOT NULL CHECK (length(display_json) > 1),
    FOREIGN KEY (generation) REFERENCES local_project(generation)
        DEFERRABLE INITIALLY DEFERRED
);
