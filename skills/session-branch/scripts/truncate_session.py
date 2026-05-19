"""Truncate a branched session's events.jsonl by removing the last N user turns.

Usage:
    python truncate_session.py <NEW_SESSION_DIR> <TURNS_BACK>

Counts user.message events as turns. Removes everything from (and including)
the Nth-from-last user message onward. Exits non-zero if TURNS_BACK exceeds
the number of available user turns.
"""

import json
import sys
from pathlib import Path


def main(argv):
    if len(argv) != 3:
        raise SystemExit("Usage: truncate_session.py <NEW_SESSION_DIR> <TURNS_BACK>")

    session_dir = Path(argv[1])
    try:
        turns_back = int(argv[2])
    except ValueError:
        raise SystemExit(f"TURNS_BACK must be an integer, got: {argv[2]!r}")
    if turns_back < 1:
        raise SystemExit("TURNS_BACK must be >= 1")

    events_file = session_dir / "events.jsonl"
    if not events_file.exists():
        raise SystemExit(f"Missing events file: {events_file}")

    events = [
        json.loads(line)
        for line in events_file.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    user_msgs = [
        (index, event)
        for index, event in enumerate(events)
        if event.get("type") == "user.message"
    ]
    if turns_back >= len(user_msgs):
        print(f"Error: only {len(user_msgs)} turns exist", file=sys.stderr)
        sys.exit(1)

    cut_idx = user_msgs[-turns_back][0]
    events = events[:cut_idx]
    events_file.write_text(
        "".join(json.dumps(event, separators=(",", ":")) + "\n" for event in events),
        encoding="utf-8",
    )
    print(f"Truncated to {len(events)} events (removed last {turns_back} turns)")


if __name__ == "__main__":
    main(sys.argv)
