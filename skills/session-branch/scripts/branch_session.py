"""Branch a Copilot CLI session into a new session directory.

Usage:
    python branch_session.py <CURRENT_SESSION_DIR> <NEW_SESSION_DIR> <CURRENT_SESSION_ID> <NEW_SESSION_ID>

Copies the current session directory into a temporary staging directory
beside the final destination, rewrites identity and title metadata in
workspace.yaml (YAML-aware: block scalars, block mappings, and trailing
comments are handled correctly), fixes session.start event metadata,
resets rewind snapshots / checkpoints, removes the per-session database
and stale in-use locks, validates that the rewritten workspace.yaml has
no duplicate top-level keys, and atomically renames the staging directory
to the final destination. On any failure the staging directory is removed
so the state directory never contains a half-branched session.

Prints NEW_SESSION_ID, NEW_SESSION_NAME, and NEW_SESSION_PATH on success
so callers can capture them.

Uses only the Python standard library.
"""

import datetime as dt
import json
import re
import shutil
import sys
import uuid
from pathlib import Path


# ---------------------------------------------------------------------------
# YAML-aware top-level rewriter
#
# workspace.yaml is a small, hand-edited YAML 1.x document. We need to
# replace a fixed set of top-level keys (id, name, summary, user_named,
# created_at, updated_at, branch_of, branch_note) while preserving every
# other line. We deliberately avoid PyYAML because it isn't part of the
# Python standard library and we want this skill to work on stock Python.
# Instead we parse just enough YAML to recognize where each top-level key's
# *span* starts and ends, including block scalars (|, |-, |+, >, >-, >+,
# optional indentation digit) and block mappings / sequences whose bodies
# are indented under the key.
# ---------------------------------------------------------------------------

# Block scalar header: `|`, `>`, optionally followed by chomping indicator
# (-, +) and/or indentation indicator digit, in either order, plus optional
# trailing whitespace and comment.
_BLOCK_SCALAR_HEADER_RE = re.compile(r"^[|>][+\-\d]{0,2}\s*(#.*)?$")
_TRAILING_COMMENT_RE = re.compile(r"\s+#.*$")


def parse_scalar(value):
    """Parse a simple flow-style scalar value (quoted or unquoted)."""
    value = value.strip()
    # Strip trailing inline comment for unquoted values (best-effort).
    if value and value[0] not in ('"', "'"):
        value = _TRAILING_COMMENT_RE.sub("", value)
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return value[1:-1]
    if len(value) >= 2 and value[0] == "'" and value[-1] == "'":
        return value[1:-1].replace("''", "'")
    return value


def yaml_string(value):
    """Render a Python string as a safely-quoted YAML scalar (JSON-compatible)."""
    return json.dumps(value, ensure_ascii=True)


def compact(value, max_len=72):
    """Collapse whitespace and truncate to a single short title line."""
    value = " ".join((value or "").split())
    if len(value) <= max_len:
        return value
    return value[: max_len - 3].rstrip() + "..."


def parse_top_level_entries(lines):
    """Parse `lines` (list[str], without trailing newlines) into top-level entries.

    Returns a list of dicts with:
        key (str)            top-level key name
        header_index (int)   line index of `key: ...` (0-based)
        end_index (int)      last line index belonging to this key (inclusive)
        is_block (bool)      True iff value is a block scalar OR block mapping
        raw_value (str)      text after ':' on the header line, stripped
        body_lines (list)    indented body lines (empty for plain scalars)

    Blank lines and comment-only lines at top level are skipped. Indented
    lines that follow a block header are absorbed into that entry's span.
    A trailing run of blank lines is *not* absorbed into the preceding
    block; those blanks logically separate two top-level entries.
    """
    entries = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        # Skip blank lines and comment-only lines at the top level.
        if line.strip() == "" or line.lstrip().startswith("#"):
            i += 1
            continue
        # Skip lines that start with whitespace and aren't owned by a key
        # (orphan indented content — shouldn't happen for valid YAML, but
        # we defend against partially-corrupted input).
        if line[:1] in (" ", "\t"):
            i += 1
            continue
        colon_idx = line.find(":")
        if colon_idx == -1:
            i += 1
            continue

        key = line[:colon_idx].strip()
        rest = line[colon_idx + 1 :].lstrip()
        rest_no_comment = _TRAILING_COMMENT_RE.sub("", rest)
        is_block_scalar = bool(_BLOCK_SCALAR_HEADER_RE.match(rest_no_comment))
        is_empty_header = rest_no_comment == ""
        is_block = is_block_scalar or is_empty_header

        end = i
        body_lines = []
        if is_block:
            j = i + 1
            while j < n and (
                lines[j].strip() == "" or lines[j][:1] in (" ", "\t")
            ):
                j += 1
            # Don't absorb a trailing run of blank lines into this key; those
            # blanks belong between this key and the next.
            while j > i + 1 and lines[j - 1].strip() == "":
                j -= 1
            body_lines = lines[i + 1 : j]
            end = j - 1

        entries.append(
            {
                "key": key,
                "header_index": i,
                "end_index": end,
                "is_block": is_block,
                "raw_value": rest,
                "body_lines": list(body_lines),
            }
        )
        i = end + 1
    return entries


def reconstruct_block_scalar(raw_header, body_lines):
    """Approximate the string value of a block scalar.

    Good enough for deriving a branch title from an existing session name.
    Strips the common leading indentation, joins literal blocks with '\\n',
    folds folded blocks with ' ' (blank lines become single newlines),
    applies '-' chomping (strip trailing newlines) when indicated.
    """
    nonblank = [l for l in body_lines if l.strip()]
    if not nonblank:
        return ""
    indent = min(len(l) - len(l.lstrip(" ")) for l in nonblank)
    stripped = [(l[indent:] if len(l) >= indent else "") for l in body_lines]

    style = raw_header[:1] if raw_header else "|"
    if style == ">":
        out_parts = []
        for l in stripped:
            if l.strip() == "":
                out_parts.append("\n")
            else:
                if out_parts and not out_parts[-1].endswith("\n"):
                    out_parts.append(" ")
                out_parts.append(l)
        text = "".join(out_parts)
    else:
        text = "\n".join(stripped)

    chomp = ""
    for ch in raw_header[1:3]:
        if ch in ("-", "+"):
            chomp = ch
            break
    if chomp == "-":
        text = text.rstrip("\n")
    return text


def get_top_level_value(lines, key):
    """Return the value of the first top-level occurrence of `key`, or None.

    For block scalars, returns the reconstructed body text. For plain scalars,
    returns the parsed scalar (json.loads-quoted strings unwrap correctly).
    """
    for entry in parse_top_level_entries(lines):
        if entry["key"] == key:
            if entry["is_block"] and entry["body_lines"]:
                return reconstruct_block_scalar(entry["raw_value"], entry["body_lines"])
            if entry["is_block"]:
                # Empty block header (e.g. block mapping with no body parsed) —
                # treat as missing rather than fabricate a value.
                return None
            return parse_scalar(entry["raw_value"])
    return None


def replace_or_append(lines, key, new_line):
    """Replace the first top-level occurrence of `key` with `new_line`.

    Removes the *entire* span of the old entry (including any block scalar
    body or block-mapping body). If `key` is absent, appends `new_line` at
    the end. Raises ValueError if `key` appears more than once at the top
    level.
    """
    entries = parse_top_level_entries(lines)
    matches = [e for e in entries if e["key"] == key]
    if len(matches) > 1:
        raise ValueError(f"Duplicate top-level key {key!r} in workspace.yaml")
    if not matches:
        lines.append(new_line)
        return
    entry = matches[0]
    lines[entry["header_index"] : entry["end_index"] + 1] = [new_line]


def validate_workspace(path):
    """Re-parse `path` and raise ValueError if any top-level key is duplicated
    or any line is orphan-indented (not absorbed into a key's span).
    """
    text = Path(path).read_text(encoding="utf-8")
    lines = text.splitlines()
    entries = parse_top_level_entries(lines)
    counts = {}
    for entry in entries:
        counts[entry["key"]] = counts.get(entry["key"], 0) + 1
    dups = {k: c for k, c in counts.items() if c > 1}
    if dups:
        raise ValueError(f"Duplicate top-level keys in {path}: {dups}")

    # Detect orphan-indented lines that aren't covered by any entry span.
    covered = set()
    for entry in entries:
        for idx in range(entry["header_index"], entry["end_index"] + 1):
            covered.add(idx)
    for idx, line in enumerate(lines):
        if idx in covered:
            continue
        if line and line[:1] in (" ", "\t"):
            raise ValueError(
                f"Orphan indented line at {path}:{idx + 1}: {line!r}"
            )


# ---------------------------------------------------------------------------
# Branch operation
# ---------------------------------------------------------------------------

CHECKPOINT_INDEX_HEADER = (
    "# Checkpoint History\n\n"
    "Checkpoints are listed in chronological order. Checkpoint 1 is the oldest, "
    "higher numbers are more recent.\n\n"
    "| # | Title | File |\n"
    "|---|-------|------|\n"
)

REWIND_INDEX_JSON = '{"version":1,"snapshots":[],"filePathMap":{}}\n'


def _rewrite_workspace_yaml(staging, current_workspace_path, current_session_id,
                            new_session_id, base_title, branch_title, now):
    """Rewrite workspace.yaml in the staging dir with the new identity/lineage.

    Returns the rewritten line list (mainly for testability).
    """
    new_workspace_path = staging / "workspace.yaml"
    workspace_lines = new_workspace_path.read_text(encoding="utf-8").splitlines()

    updates = [
        ("id", new_session_id),
        ("name", yaml_string(branch_title)),
        ("user_named", "true"),
        ("summary", yaml_string(branch_title)),
        ("created_at", now),
        ("updated_at", now),
        ("branch_of", current_session_id),
        ("branch_note", yaml_string(f"Branched from: {base_title} ({current_session_id})")),
    ]
    for key, value in updates:
        replace_or_append(workspace_lines, key, f"{key}: {value}")

    new_workspace_path.write_text("\n".join(workspace_lines) + "\n", encoding="utf-8")
    validate_workspace(new_workspace_path)
    return workspace_lines


def _rewrite_events_jsonl(staging, new_session_id, branch_title):
    """Update session.start metadata in events.jsonl, if present."""
    events_path = staging / "events.jsonl"
    if not events_path.exists():
        return
    rewritten = []
    for line in events_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        event = json.loads(line)
        if event.get("type") == "session.start":
            data = event.setdefault("data", {})
            data["sessionId"] = new_session_id
            if "alreadyInUse" in data:
                data["alreadyInUse"] = False
            for k in ("name", "title", "summary"):
                if k in data:
                    data[k] = branch_title
        rewritten.append(json.dumps(event, separators=(",", ":"), ensure_ascii=False))
    events_path.write_text("\n".join(rewritten) + "\n", encoding="utf-8")


def _reset_rewind_state(staging):
    rewind_dir = staging / "rewind-snapshots"
    rewind_dir.mkdir(exist_ok=True)
    (rewind_dir / "index.json").write_text(REWIND_INDEX_JSON, encoding="utf-8")
    backup_dir = rewind_dir / "backups"
    if backup_dir.exists():
        for child in backup_dir.iterdir():
            if child.is_dir():
                shutil.rmtree(child)
            else:
                child.unlink()


def _reset_checkpoints(staging):
    checkpoint_dir = staging / "checkpoints"
    checkpoint_dir.mkdir(exist_ok=True)
    (checkpoint_dir / "index.md").write_text(CHECKPOINT_INDEX_HEADER, encoding="utf-8")


def _drop_session_locks(staging):
    for path in [staging / "session.db", *staging.glob("inuse.*.lock")]:
        if path.exists():
            path.unlink()


def branch_session(current_session, new_session, current_session_id, new_session_id):
    """Branch `current_session` into `new_session` atomically.

    Returns (branch_title, str(new_session)) on success.
    Raises on any failure; staging directory is cleaned up automatically.
    """
    current_session = Path(current_session)
    new_session = Path(new_session)

    workspace_path = current_session / "workspace.yaml"
    if not workspace_path.exists():
        raise SystemExit(f"Missing workspace metadata: {workspace_path}")
    if new_session.exists():
        raise SystemExit(f"Branch destination already exists: {new_session}")

    # Derive the base title from the source (block-scalar aware), so we don't
    # accidentally derive "|-" from a block-header line.
    current_lines = workspace_path.read_text(encoding="utf-8").splitlines()
    base_title = (
        get_top_level_value(current_lines, "name")
        or get_top_level_value(current_lines, "summary")
        or f"Session {current_session_id[:8]}"
    )
    branch_title = f"Branch: {compact(base_title)} [{new_session_id[:8]}]"
    now = (
        dt.datetime.now(dt.timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )

    # Stage in a sibling temp directory so the final rename is atomic
    # (same parent filesystem). Clean up on any exception.
    parent = new_session.parent
    parent.mkdir(parents=True, exist_ok=True)
    staging = parent / f".tmp-branch-{uuid.uuid4().hex}"

    try:
        shutil.copytree(current_session, staging)
        _rewrite_workspace_yaml(
            staging, workspace_path, current_session_id, new_session_id,
            base_title, branch_title, now,
        )
        _rewrite_events_jsonl(staging, new_session_id, branch_title)
        _reset_rewind_state(staging)
        _reset_checkpoints(staging)
        _drop_session_locks(staging)
        # Final atomic move into place. On the same filesystem this is atomic
        # on POSIX; on Windows it is atomic for directories on the same volume.
        staging.rename(new_session)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise

    return branch_title, str(new_session)


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

    branch_title, new_session_str = branch_session(
        current_session, new_session, current_session_id, new_session_id,
    )

    print(f"NEW_SESSION_ID={new_session_id}")
    print(f"NEW_SESSION_NAME={branch_title}")
    print(f"NEW_SESSION_PATH={new_session_str}")


if __name__ == "__main__":
    main(sys.argv)
