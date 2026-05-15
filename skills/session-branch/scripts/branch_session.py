"""Branch a Copilot CLI session into a new session directory.

Usage:
    python branch_session.py <CURRENT_SESSION_DIR> <NEW_SESSION_DIR> <CURRENT_SESSION_ID> <NEW_SESSION_ID>

Copies the current session directory to the new location, rewrites identity
and title metadata in workspace.yaml, fixes session.start event metadata,
resets rewind snapshots / checkpoints, and removes the per-session database
and stale in-use locks. Prints NEW_SESSION_ID, NEW_SESSION_NAME, and
NEW_SESSION_PATH on success so callers can capture them.
"""

import datetime as dt
import json
import shutil
import sys
from pathlib import Path


def parse_scalar(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return value[1:-1]
    if len(value) >= 2 and value[0] == "'" and value[-1] == "'":
        return value[1:-1].replace("''", "'")
    return value


def read_top_level_fields(path):
    fields = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line and not line.startswith(" ") and ":" in line:
            key, value = line.split(":", 1)
            fields[key] = parse_scalar(value)
    return fields


def yaml_string(value):
    return json.dumps(value, ensure_ascii=True)


def compact(value, max_len=72):
    value = " ".join((value or "").split())
    if len(value) <= max_len:
        return value
    return value[: max_len - 3].rstrip() + "..."


def set_top_level(lines, key, value):
    prefix = f"{key}:"
    for index, line in enumerate(lines):
        if line.startswith(prefix):
            lines[index] = f"{key}: {value}"
            return
    lines.append(f"{key}: {value}")


def main(argv):
    if len(argv) != 5:
        raise SystemExit(
            "Usage: branch_session.py <CURRENT_SESSION_DIR> <NEW_SESSION_DIR> "
            "<CURRENT_SESSION_ID> <NEW_SESSION_ID>"
        )

    current_session = Path(argv[1])
    new_session = Path(argv[2])
    current_session_id = argv[3]
    new_session_id = argv[4]

    workspace_path = current_session / "workspace.yaml"
    if not workspace_path.exists():
        raise SystemExit(f"Missing workspace metadata: {workspace_path}")
    if new_session.exists():
        raise SystemExit(f"Branch destination already exists: {new_session}")

    current_fields = read_top_level_fields(workspace_path)
    base_title = (
        current_fields.get("name")
        or current_fields.get("summary")
        or f"Session {current_session_id[:8]}"
    )
    branch_title = f"Branch: {compact(base_title)} [{new_session_id[:8]}]"
    now = dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")

    # Copy the session, then rewrite identity and title metadata in the branch.
    shutil.copytree(current_session, new_session)

    new_workspace_path = new_session / "workspace.yaml"
    workspace_lines = new_workspace_path.read_text(encoding="utf-8").splitlines()
    set_top_level(workspace_lines, "id", new_session_id)
    set_top_level(workspace_lines, "name", yaml_string(branch_title))
    set_top_level(workspace_lines, "user_named", "true")
    set_top_level(workspace_lines, "summary", yaml_string(branch_title))
    set_top_level(workspace_lines, "created_at", now)
    set_top_level(workspace_lines, "updated_at", now)
    set_top_level(workspace_lines, "branch_of", current_session_id)
    set_top_level(
        workspace_lines,
        "branch_note",
        yaml_string(f"Branched from: {base_title} ({current_session_id})"),
    )
    new_workspace_path.write_text("\n".join(workspace_lines) + "\n", encoding="utf-8")

    # Fix session.start event metadata to reference the new session ID.
    events_path = new_session / "events.jsonl"
    if events_path.exists():
        rewritten_events = []
        for line in events_path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            event = json.loads(line)
            if event.get("type") == "session.start":
                data = event.setdefault("data", {})
                data["sessionId"] = new_session_id
                if "alreadyInUse" in data:
                    data["alreadyInUse"] = False
                for key in ("name", "title", "summary"):
                    if key in data:
                        data[key] = branch_title
            rewritten_events.append(json.dumps(event, separators=(",", ":"), ensure_ascii=False))
        events_path.write_text("\n".join(rewritten_events) + "\n", encoding="utf-8")

    # Reset rewind snapshots (they reference old event state).
    rewind_dir = new_session / "rewind-snapshots"
    rewind_dir.mkdir(exist_ok=True)
    (rewind_dir / "index.json").write_text(
        '{"version":1,"snapshots":[],"filePathMap":{}}\n',
        encoding="utf-8",
    )
    backup_dir = rewind_dir / "backups"
    if backup_dir.exists():
        for child in backup_dir.iterdir():
            if child.is_dir():
                shutil.rmtree(child)
            else:
                child.unlink()

    # Reset per-session database and stale in-use locks.
    for path in [new_session / "session.db", *new_session.glob("inuse.*.lock")]:
        if path.exists():
            path.unlink()

    # Reset checkpoints.
    checkpoint_dir = new_session / "checkpoints"
    checkpoint_dir.mkdir(exist_ok=True)
    (checkpoint_dir / "index.md").write_text(
        "# Checkpoint History\n\n"
        "Checkpoints are listed in chronological order. Checkpoint 1 is the oldest, higher numbers are more recent.\n\n"
        "| # | Title | File |\n"
        "|---|-------|------|\n",
        encoding="utf-8",
    )

    print(f"NEW_SESSION_ID={new_session_id}")
    print(f"NEW_SESSION_NAME={branch_title}")
    print(f"NEW_SESSION_PATH={new_session}")


if __name__ == "__main__":
    main(sys.argv)
