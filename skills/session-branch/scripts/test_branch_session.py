"""Unit tests for branch_session.

Run with:
    python -m unittest test_branch_session
or:
    python test_branch_session.py
"""

import json
import shutil
import tempfile
import unittest
from pathlib import Path

import branch_session as bs


SID_OLD = "11111111-1111-1111-1111-111111111111"
SID_NEW = "22222222-2222-2222-2222-222222222222"


class ParserTests(unittest.TestCase):
    def test_simple_scalar(self):
        lines = "id: abc\nname: foo\n".splitlines()
        entries = bs.parse_top_level_entries(lines)
        self.assertEqual([e["key"] for e in entries], ["id", "name"])
        self.assertFalse(entries[0]["is_block"])
        self.assertEqual(entries[0]["raw_value"], "abc")
        self.assertEqual(entries[0]["end_index"], 0)
        self.assertEqual(entries[1]["end_index"], 1)

    def test_block_scalar_literal_strip(self):
        text = "name: |-\n  line one\n  line two\nid: xyz\n"
        entries = bs.parse_top_level_entries(text.splitlines())
        self.assertEqual([e["key"] for e in entries], ["name", "id"])
        self.assertTrue(entries[0]["is_block"])
        self.assertEqual(entries[0]["body_lines"], ["  line one", "  line two"])
        self.assertEqual(entries[0]["end_index"], 2)
        self.assertEqual(entries[1]["header_index"], 3)

    def test_block_scalar_with_chomping_and_indent(self):
        for header in ["|", "|-", "|+", ">", ">-", ">+", "|2", "|-2", "|2-", ">1+"]:
            text = f"k: {header}\n  body\nnext: v\n"
            entries = bs.parse_top_level_entries(text.splitlines())
            self.assertEqual([e["key"] for e in entries], ["k", "next"], header)
            self.assertTrue(entries[0]["is_block"], header)
            self.assertEqual(entries[0]["body_lines"], ["  body"], header)

    def test_block_scalar_with_trailing_comment(self):
        text = "k: |- # this is a comment\n  body\nnext: v\n"
        entries = bs.parse_top_level_entries(text.splitlines())
        self.assertEqual([e["key"] for e in entries], ["k", "next"])
        self.assertTrue(entries[0]["is_block"])
        self.assertEqual(entries[0]["body_lines"], ["  body"])

    def test_block_mapping_skipped(self):
        text = "metadata:\n  nested: value\n  another: thing\nid: top\n"
        entries = bs.parse_top_level_entries(text.splitlines())
        self.assertEqual([e["key"] for e in entries], ["metadata", "id"])
        self.assertEqual(entries[1]["header_index"], 3)
        self.assertEqual(entries[0]["body_lines"], ["  nested: value", "  another: thing"])

    def test_blank_lines_dont_get_absorbed_into_block(self):
        text = "k: |-\n  body\n\nnext: v\n"
        entries = bs.parse_top_level_entries(text.splitlines())
        # The blank line between block body and 'next' should NOT extend k's span.
        self.assertEqual(entries[0]["end_index"], 1)
        self.assertEqual(entries[1]["header_index"], 3)

    def test_blank_lines_within_block_are_absorbed(self):
        text = "k: |-\n  para1\n\n  para2\nnext: v\n"
        entries = bs.parse_top_level_entries(text.splitlines())
        self.assertEqual(entries[0]["end_index"], 3)
        self.assertEqual(entries[1]["header_index"], 4)

    def test_comments_and_blanks_ignored_at_top_level(self):
        text = "# header comment\n\nid: x\n# another\nname: y\n"
        entries = bs.parse_top_level_entries(text.splitlines())
        self.assertEqual([e["key"] for e in entries], ["id", "name"])

    def test_plain_value_with_pipe_is_not_block(self):
        # `|abc` is not a valid block scalar header indicator; treat as plain.
        text = "k: |abc\nnext: v\n"
        entries = bs.parse_top_level_entries(text.splitlines())
        self.assertFalse(entries[0]["is_block"])

    def test_get_top_level_value_literal_block(self):
        text = "name: |-\n  Hello\n  World\n"
        v = bs.get_top_level_value(text.splitlines(), "name")
        self.assertEqual(v, "Hello\nWorld")

    def test_get_top_level_value_folded_block(self):
        text = "summary: >\n  word1\n  word2\n"
        v = bs.get_top_level_value(text.splitlines(), "summary")
        self.assertEqual(v, "word1 word2")

    def test_get_top_level_value_simple_quoted(self):
        text = 'name: "hello"\n'
        v = bs.get_top_level_value(text.splitlines(), "name")
        self.assertEqual(v, "hello")

    def test_get_top_level_value_missing(self):
        text = "id: x\n"
        self.assertIsNone(bs.get_top_level_value(text.splitlines(), "name"))

    def test_reconstruct_literal_with_chomping(self):
        self.assertEqual(bs.reconstruct_block_scalar("|-", ["  a", "  b"]), "a\nb")
        self.assertEqual(bs.reconstruct_block_scalar("|", ["  a", "  b"]), "a\nb")

    def test_reconstruct_folded(self):
        self.assertEqual(bs.reconstruct_block_scalar(">", ["  hello", "  world"]), "hello world")

    def test_reconstruct_folded_with_blank_line(self):
        v = bs.reconstruct_block_scalar(">", ["  para1", "", "  para2"])
        self.assertEqual(v, "para1\npara2")


class ReplaceOrAppendTests(unittest.TestCase):
    def test_replace_simple(self):
        lines = ["id: old", "name: foo"]
        bs.replace_or_append(lines, "id", 'id: "new"')
        self.assertEqual(lines, ['id: "new"', "name: foo"])

    def test_replace_block_scalar_removes_body(self):
        lines = "name: |-\n  multi\n  line\nid: x".splitlines()
        bs.replace_or_append(lines, "name", 'name: "compact"')
        self.assertEqual(lines, ['name: "compact"', "id: x"])

    def test_replace_block_mapping_removes_body(self):
        # Edge case: if a key has an indented body, replace_or_append still
        # consumes the body when the key is replaced.
        lines = "metadata:\n  nested: value\n  another: thing\nid: x".splitlines()
        bs.replace_or_append(lines, "metadata", 'metadata: "flat"')
        self.assertEqual(lines, ['metadata: "flat"', "id: x"])

    def test_append_when_missing(self):
        lines = ["id: x"]
        bs.replace_or_append(lines, "user_named", "user_named: true")
        self.assertEqual(lines, ["id: x", "user_named: true"])

    def test_duplicate_raises(self):
        lines = ["id: a", "id: b"]
        with self.assertRaises(ValueError):
            bs.replace_or_append(lines, "id", "id: c")


class ValidateTests(unittest.TestCase):
    def _write(self, text):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        p = Path(d) / "workspace.yaml"
        p.write_text(text, encoding="utf-8")
        return p

    def test_valid_passes(self):
        p = self._write("id: a\nname: b\n")
        bs.validate_workspace(p)  # no raise

    def test_duplicate_key_fails(self):
        p = self._write("id: a\nid: b\n")
        with self.assertRaises(ValueError) as cm:
            bs.validate_workspace(p)
        self.assertIn("Duplicate", str(cm.exception))

    def test_orphan_indented_line_fails(self):
        # Simulate the exact corruption shape the old line-based rewriter
        # produced for block-scalar values.
        p = self._write('name: "new"\n  orphan from old block\nid: x\n')
        with self.assertRaises(ValueError) as cm:
            bs.validate_workspace(p)
        self.assertIn("Orphan", str(cm.exception))

    def test_block_scalar_body_not_treated_as_orphan(self):
        p = self._write("name: |-\n  legitimate block body\nid: x\n")
        bs.validate_workspace(p)  # no raise


class BranchSessionEndToEndTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmpdir, ignore_errors=True)

    def _make_session(self, sid, workspace_yaml, events=None):
        sdir = self.tmpdir / sid
        sdir.mkdir()
        (sdir / "workspace.yaml").write_text(workspace_yaml, encoding="utf-8")
        events = events if events is not None else [
            {"type": "session.start", "data": {"sessionId": sid, "name": "x"}}
        ]
        (sdir / "events.jsonl").write_text(
            "\n".join(json.dumps(e) for e in events) + "\n", encoding="utf-8",
        )
        return sdir

    def test_branch_with_block_scalar_name(self):
        """The RCA repro: name: |- with a multi-line body must produce a
        parseable workspace.yaml with a non-trivial branch title and no
        orphaned indented lines."""
        src = self._make_session(
            SID_OLD,
            f"id: {SID_OLD}\n"
            "name: |-\n"
            "  This is a multi-line\n"
            "  session name from a\n"
            "  long launch prompt\n"
            "summary: short summary\n"
            "cwd: C:\\some\\where\n"
            "created_at: 2026-01-01T00:00:00.000Z\n"
            "updated_at: 2026-01-01T00:00:00.000Z\n",
        )
        dst = self.tmpdir / SID_NEW
        title, _ = bs.branch_session(src, dst, SID_OLD, SID_NEW)

        # Branch title must come from the real content, not from the '|-' header.
        self.assertNotIn("|-", title)
        self.assertIn("This is a multi-line", title)
        self.assertIn(SID_NEW[:8], title)

        # Workspace.yaml must validate cleanly (no orphans, no dupes).
        bs.validate_workspace(dst / "workspace.yaml")

        # Identity rewritten.
        ws = (dst / "workspace.yaml").read_text(encoding="utf-8")
        self.assertIn(f"id: {SID_NEW}", ws)
        self.assertIn(f"branch_of: {SID_OLD}", ws)
        self.assertIn("user_named: true", ws)
        # The original block-body lines must NOT survive as orphan indented
        # content (the RCA's exact corruption shape). The literal phrase from
        # the source legitimately appears inside the new branch title, so we
        # check that no top-level line has a stray indented continuation line
        # following it (which is what validate_workspace asserts above, but
        # we double-check here for clarity).
        ws_lines = ws.splitlines()
        for idx, line in enumerate(ws_lines):
            if line and line[0] in (" ", "\t"):
                self.fail(f"Orphan indented line {idx + 1}: {line!r}\n--- full file ---\n{ws}")

    def test_branch_with_folded_summary(self):
        src = self._make_session(
            SID_OLD,
            f"id: {SID_OLD}\n"
            "name: simple\n"
            "summary: >\n"
            "  folded\n"
            "  summary\n",
        )
        dst = self.tmpdir / SID_NEW
        title, _ = bs.branch_session(src, dst, SID_OLD, SID_NEW)
        bs.validate_workspace(dst / "workspace.yaml")
        # Title comes from `name` (truthy) so summary isn't consulted, but the
        # rewrite must still consume the folded summary body cleanly.
        ws = (dst / "workspace.yaml").read_text(encoding="utf-8")
        self.assertNotIn("folded\n  summary", ws)

    def test_branch_simple_name(self):
        src = self._make_session(
            SID_OLD,
            f"id: {SID_OLD}\nname: My Project\ncwd: /tmp/x\n",
        )
        dst = self.tmpdir / SID_NEW
        title, _ = bs.branch_session(src, dst, SID_OLD, SID_NEW)
        self.assertIn("My Project", title)
        self.assertIn(SID_NEW[:8], title)
        bs.validate_workspace(dst / "workspace.yaml")

    def test_events_jsonl_session_start_rewritten(self):
        src = self._make_session(
            SID_OLD,
            f"id: {SID_OLD}\nname: x\n",
            events=[
                {"type": "session.start", "data": {"sessionId": SID_OLD, "name": "x", "alreadyInUse": True}},
                {"type": "user.message", "data": {"content": "hi"}},
            ],
        )
        dst = self.tmpdir / SID_NEW
        bs.branch_session(src, dst, SID_OLD, SID_NEW)
        events = [
            json.loads(l) for l in (dst / "events.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()
        ]
        self.assertEqual(events[0]["data"]["sessionId"], SID_NEW)
        self.assertFalse(events[0]["data"]["alreadyInUse"])
        self.assertIn(SID_NEW[:8], events[0]["data"]["name"])
        # Non-session.start events untouched.
        self.assertEqual(events[1]["data"]["content"], "hi")

    def test_session_locks_and_db_removed(self):
        src = self._make_session(SID_OLD, f"id: {SID_OLD}\nname: x\n")
        (src / "session.db").write_bytes(b"sqlite-stub")
        (src / "inuse.host123.lock").write_text("locked", encoding="utf-8")
        dst = self.tmpdir / SID_NEW
        bs.branch_session(src, dst, SID_OLD, SID_NEW)
        self.assertFalse((dst / "session.db").exists())
        self.assertFalse((dst / "inuse.host123.lock").exists())

    def test_rewind_and_checkpoint_reset(self):
        src = self._make_session(SID_OLD, f"id: {SID_OLD}\nname: x\n")
        rewind = src / "rewind-snapshots"
        rewind.mkdir()
        (rewind / "index.json").write_text('{"version":1,"snapshots":[{"old":true}]}', encoding="utf-8")
        (rewind / "backups").mkdir()
        (rewind / "backups" / "snap-1").mkdir()
        (rewind / "backups" / "snap-1" / "file.txt").write_text("old", encoding="utf-8")
        (src / "checkpoints").mkdir()
        (src / "checkpoints" / "index.md").write_text("old checkpoint history", encoding="utf-8")

        dst = self.tmpdir / SID_NEW
        bs.branch_session(src, dst, SID_OLD, SID_NEW)

        new_rewind = (dst / "rewind-snapshots" / "index.json").read_text(encoding="utf-8")
        self.assertIn('"snapshots":[]', new_rewind)
        self.assertFalse((dst / "rewind-snapshots" / "backups" / "snap-1").exists())
        new_ckpt = (dst / "checkpoints" / "index.md").read_text(encoding="utf-8")
        self.assertIn("Checkpoint History", new_ckpt)
        self.assertNotIn("old checkpoint history", new_ckpt)

    def test_failure_cleans_up_staging_and_leaves_no_destination(self):
        """If the source has a duplicate top-level key, replace_or_append must
        raise, the destination must not exist, and the staging dir must be gone.
        """
        src = self._make_session(
            SID_OLD,
            # Duplicate `id` triggers the validation in replace_or_append.
            f"id: {SID_OLD}\nid: dup\nname: x\n",
        )
        dst = self.tmpdir / SID_NEW
        with self.assertRaises(ValueError):
            bs.branch_session(src, dst, SID_OLD, SID_NEW)
        self.assertFalse(dst.exists())
        staging = list(self.tmpdir.glob(".tmp-branch-*"))
        self.assertEqual(staging, [], f"Staging left behind: {staging}")

    def test_failure_when_destination_exists(self):
        src = self._make_session(SID_OLD, f"id: {SID_OLD}\nname: x\n")
        dst = self.tmpdir / SID_NEW
        dst.mkdir()
        with self.assertRaises(SystemExit):
            bs.branch_session(src, dst, SID_OLD, SID_NEW)
        # Pre-existing destination is preserved; no staging dir left behind.
        self.assertTrue(dst.exists())
        staging = list(self.tmpdir.glob(".tmp-branch-*"))
        self.assertEqual(staging, [])


if __name__ == "__main__":
    unittest.main()
