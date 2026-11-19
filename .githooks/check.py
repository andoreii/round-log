#!/usr/bin/env python3
"""Small checks for commit messages and staged files."""

import pathlib
import re
import subprocess
import sys
import tempfile

MAX_BYTES = 5 * 1024 * 1024
MENTIONS = re.compile(r"\b(?:AI|Codex|ChatGPT)\b", re.IGNORECASE)
COAUTHOR = re.compile(r"^\s*Co-authored-by\s*:", re.IGNORECASE | re.MULTILINE)
NOTICE = re.compile(r"^(?:LICENSE|LICENCE|COPYING|NOTICE|THIRD[-_]PARTY)(?:[._-]|$)", re.IGNORECASE)
LOCKFILES = {"Package.resolved", "package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "yarn.lock", "uv.lock", "poetry.lock"}


def git(*args):
    return subprocess.check_output(["git", *args])


def message_issues(message):
    issues = []
    if COAUTHOR.search(message):
        issues.append("Remove co-author trailers.")
    if MENTIONS.search(message):
        issues.append("Remove restricted tool mentions.")
    return issues


def excluded(path):
    parts = pathlib.PurePosixPath(path).parts
    return (any(part in {".githooks", "vendor", "third_party", "third-party", "node_modules"} for part in parts)
            or path.endswith(".lock") or parts[-1] in LOCKFILES or bool(NOTICE.match(parts[-1])))


def file_issues(path, content):
    if len(content) > MAX_BYTES:
        return [f"{path}: exceeds 5 MiB; keep generated or large files outside the repository."]
    if excluded(path) or b"\0" in content:
        return []
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError:
        return []
    return [f"{path}: remove restricted tool mentions."] if MENTIONS.search(text) else []


def staged_issues():
    changed = set(git("diff", "--cached", "--name-only", "--diff-filter=ACMRT", "-z").split(b"\0"))
    issues = []
    for entry in git("ls-files", "--stage", "-z").split(b"\0"):
        if not entry:
            continue
        header, path_bytes = entry.split(b"\t", 1)
        mode, object_id, stage = header.split()
        if path_bytes not in changed or stage != b"0" or mode == b"160000":
            continue
        path = path_bytes.decode("utf-8", errors="replace")
        size = int(git("cat-file", "-s", object_id.decode()))
        if size > MAX_BYTES:
            issues.append(f"{path}: exceeds 5 MiB; keep generated or large files outside the repository.")
        elif not excluded(path):
            issues.extend(file_issues(path, git("cat-file", "blob", object_id.decode())))
    return issues


def self_test():
    assert message_issues("Fix putt entry") == []
    assert message_issues("Fix scoring\n\nCo-Authored-By: Someone <person@example.com>")
    for word in ("AI", "codex", "ChatGPT"):
        assert message_issues(f"Made with {word}")
        assert file_issues("README.md", word.encode())
    assert not message_issues("Repair fairway detail")
    assert not file_issues(".githooks/check.py", b"AI")
    assert not file_issues("Package.resolved", b"Codex")
    assert not file_issues("NOTICE.txt", b"ChatGPT")
    assert not file_issues("icon.png", b"\0AI")
    assert file_issues("large.bin", b"\0" * (MAX_BYTES + 1))
    script = str(pathlib.Path(__file__).resolve())
    with tempfile.TemporaryDirectory(prefix="round-log-hooks-") as directory:
        def run(*args):
            return subprocess.run(args, cwd=directory, capture_output=True)
        assert run("git", "init", "-q").returncode == 0
        file = pathlib.Path(directory, "notes.md")
        file.write_text("AI")
        assert run("git", "add", "notes.md").returncode == 0
        file.write_text("Clean working copy")
        assert run(sys.executable, "-B", script, "pre-commit").returncode == 1
        assert run("git", "add", "notes.md").returncode == 0
        assert run(sys.executable, "-B", script, "pre-commit").returncode == 0
    print("Hook checks passed.")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        sys.exit(0)
    if sys.argv[1:2] == ["commit-msg"] and len(sys.argv) == 3:
        issues = message_issues(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8", errors="replace"))
    elif sys.argv[1:] == ["pre-commit"]:
        issues = staged_issues()
    else:
        sys.exit("Usage: check.py pre-commit | commit-msg FILE | --self-test")
    if issues:
        print("\n".join(issues), file=sys.stderr)
        sys.exit(1)
