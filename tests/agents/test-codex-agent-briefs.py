#!/usr/bin/env python3
"""Codex agent TOMLs are the only guard (no Claude hooks).

Each .codex/agents/<role>.toml developer_instructions must cover the normative
lines of agents/<role>.md, plus the Codex-only rules that the markdown leaves
to hooks (no commit/push on main, read-only reviewer, and so on).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ROLES = ("orchestrator", "planner", "implementer", "reviewer", "qa", "documenter")
WORKERS = ("planner", "implementer", "reviewer", "qa", "documenter")
MAX_DO_NOT = 6

# Codex adaptations that are not always spelled out in the Claude brief,
# because Claude enforces them with hooks. They must still be in the TOML.
CODEX_REQUIRED = {
    "orchestrator": [
        "state:review",
        "worktree",
        "main",
        "never force-push",
        ".relentless/config.json",
    ],
    "planner": [
        "proposed",
        "--status accepted",
        "human:pending",
        "do not implement",
        "main",
    ],
    "implementer": [
        "state:review",
        "stop",
        "never commit",
        "never push",
        "main",
        "self-review",
        "do not merge",
        "review:approved",
        "stash",
        "uncommitted",
    ],
    "reviewer": [
        "read-only",
        "acceptance criteria",
        "diff",
        "qa",
        "adr",
        "do not edit",
        "do not commit",
        "approved",
        "changes_requested",
        "blocker",
        "verdict rule",
        "follow-ups",
        "decisions.md",
    ],
    "qa": [
        "dogfood",
        "fill-qa-section",
        "do not silently patch",
        "follow-up",
        "readme",
        "docs/decisions",
        "do not merge",
        "main",
        "human:pending",
    ],
    "documenter": [
        "milestone close",
        "write-status-snapshot",
        "docs/decisions",
        "readme",
        "review:approved",
        "human-gated",
        "main",
        "human:pending",
    ],
}

DENY_NAMES = ("marcelus", "fernandes")
# Core briefs (orchestrator, implementer) are compared as text, not by keyword.
# Layer sentences live in agents/layers/ and are not part of this comparison.
CORE_ROLES = ("orchestrator", "implementer")
HUMAN_DECIDED_SENTENCE = (
    "Never add `human:decided` and never decide for the human, even when the answer looks obvious."
)
STOPWORDS = {
    "about", "after", "again", "agent", "agents", "allow", "allows", "along",
    "already", "another", "apply", "around", "because", "before", "being",
    "below", "between", "brief", "could", "every", "exists", "first", "fresh",
    "human", "issue", "issues", "never", "other", "please", "should", "still",
    "their", "there", "these", "those", "under", "using", "which", "while",
    "would", "write", "writes", "your",
}


def strip_frontmatter(text: str) -> tuple[str, str]:
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            return text[4:end], text[end + 5 :]
    return "", text


def strip_code_fences(text: str) -> str:
    return re.sub(r"```.*?```", "", text, flags=re.S)


def normative_lines(md: str) -> list[str]:
    front, body = strip_frontmatter(md)
    desc = ""
    match = re.search(r"^description:\s*(.+)$", front, re.M)
    if match:
        desc = match.group(1).strip()
    lines: list[str] = []
    if desc and any(
        phrase in desc.lower() for phrase in ("do not", "never ", "must not", "must do", " stop")
    ):
        lines.append(desc)
    in_code = False
    heading_normative = False
    for raw in strip_code_fences(body).splitlines():
        if raw.strip().startswith("```"):
            in_code = not in_code
            continue
        if in_code:
            continue
        if raw.startswith("#"):
            heading = raw.lstrip("#").strip().lower()
            heading_normative = any(
                key in heading
                for key in (
                    "do not",
                    "must not",
                    "must do",
                    "human decision",
                    "isolation",
                    "explicit failure",
                )
            )
            continue
        text = raw.strip()
        if not text:
            continue
        lowered = text.lower()
        is_bullet = bool(re.match(r"[-*]|\d+\.", text))
        if any(
            phrase in lowered
            for phrase in ("do not", "never ", "must not", "must do", " stop")
        ):
            lines.append(text)
        elif heading_normative and is_bullet:
            lines.append(text)
    return lines


def clean_token(token: str) -> str:
    return token.strip().lower().strip(".,;:!?\"'()[]")


def keywords(line: str) -> list[str]:
    found: list[str] = []
    for code in re.findall(r"`([^`]+)`", line):
        token = clean_token(code)
        if len(token) >= 4:
            found.append(token)
    plain = re.sub(r"`[^`]*`", " ", line)
    plain = re.sub(r"[*_]", "", plain)
    for word in re.findall(r"[A-Za-z][A-Za-z0-9:_./-]{3,}", plain):
        token = clean_token(word)
        if len(token) < 5 or token in STOPWORDS:
            continue
        found.append(token)
    # Preserve order, drop duplicates.
    seen: set[str] = set()
    unique: list[str] = []
    for token in found:
        if token not in seen:
            seen.add(token)
            unique.append(token)
    return unique


# Exact sentences that must appear in both the markdown brief and the Codex TOML.
# Parity is the check. Do not accept a stripped token such as startupfailure in
# place of the sentence.
SENTENCE_PARITY = {
    "implementer": [
        "If wait-ci exits 4 (CI unavailable, quota), it is not a code failure: do not change code, do not retry CI, and do not run or report checks yourself. Report back ready for review and stop; the orchestrator sets state:review; merge-if-ready runs the checks on the PR head after review.",
    ],
    "orchestrator": [],
}

# The implementer stops at review and does not take the merge step.
IMPLEMENTER_MUST_NOT = "apply merge labels or merge yourself"


def normalize_emphasis(text: str) -> str:
    """TOML briefs drop backticks and bold. Nothing else may change."""
    return text.replace("`", "").replace("**", "").strip()


def markdown_do_not(md: str) -> list[str]:
    _, body = strip_frontmatter(md)
    items: list[str] = []
    in_section = False
    for raw in body.splitlines():
        if raw.startswith("## "):
            if in_section:
                break
            if raw.strip() == "## Do NOT":
                in_section = True
            continue
        if in_section and raw.startswith("- "):
            items.append(raw.strip())
    return items


def toml_do_not(instructions: str) -> list[str]:
    items: list[str] = []
    in_section = False
    for raw in instructions.splitlines():
        if not in_section:
            if raw.strip() == "Do NOT:":
                in_section = True
            continue
        if raw.startswith("- "):
            items.append(raw.strip())
            continue
        if raw.strip() == "":
            continue
        break
    return items


def frontmatter_tools(md: str) -> str:
    front, _ = strip_frontmatter(md)
    match = re.search(r"(?m)^tools:\s*(.+)$", front)
    return match.group(1).strip() if match else ""


def reviewer_allowed_tools(script: str) -> str:
    match = re.search(r'(?m)^REVIEWER_ALLOWED_TOOLS="([^"]*)"', script)
    return match.group(1) if match else ""


def core_markdown(md_text: str) -> str:
    _, body = strip_frontmatter(md_text)
    return body.strip()


def developer_instructions(toml_text: str) -> str:
    match = re.search(
        r'developer_instructions\s*=\s*"""(.*?)"""',
        toml_text,
        re.S,
    )
    if not match:
        return ""
    return match.group(1)


def main() -> int:
    failures: list[str] = []
    for role in ROLES:
        md_path = ROOT / "agents" / f"{role}.md"
        toml_path = ROOT / ".codex" / "agents" / f"{role}.toml"
        if not md_path.is_file():
            failures.append(f"{role}: missing {md_path}")
            continue
        if not toml_path.is_file():
            failures.append(f"{role}: missing {toml_path}")
            continue
        instructions = developer_instructions(toml_path.read_text())
        md_text = md_path.read_text()
        if role in CORE_ROLES:
            core = core_markdown(md_text)
            if not core:
                failures.append(f"{role}: markdown core is empty")
            elif core not in instructions:
                failures.append(f"{role}: TOML core differs from agents/{role}.md")
            if role == "orchestrator":
                if HUMAN_DECIDED_SENTENCE not in md_text:
                    failures.append("orchestrator: missing the separate Never add human:decided sentence")
                if HUMAN_DECIDED_SENTENCE not in instructions:
                    failures.append("orchestrator: TOML missing the separate Never add human:decided sentence")
            for name in DENY_NAMES:
                if name in instructions.lower() or name in md_text.lower():
                    failures.append(f"{role}: hardcoded name {name!r}")
            continue
        if len(instructions.strip()) < 400:
            failures.append(f"{role}: developer_instructions missing or too short")
            continue
        lowered = instructions.lower()
        # Same emphasis stripping as keywords(), so startup_failure matches
        # without planting the glued token startupfailure in the brief.
        normalized = re.sub(r"[*_]", "", lowered)
        md_text = md_path.read_text()
        for name in DENY_NAMES:
            if name in lowered:
                failures.append(f"{role}: hardcoded name {name!r} in developer_instructions")
        for phrase in CODEX_REQUIRED[role]:
            if phrase not in lowered:
                failures.append(f"{role}: Codex rule missing from TOML: {phrase}")
        for sentence in SENTENCE_PARITY.get(role, []):
            if sentence not in md_text:
                failures.append(f"{role}: markdown brief missing sentence: {sentence}")
            if sentence not in instructions:
                failures.append(f"{role}: TOML missing the same sentence: {sentence}")
        if role == "implementer" and IMPLEMENTER_MUST_NOT in md_text:
            failures.append("implementer: orchestrator merge-if-ready sentence leaked into the markdown brief")
        if role == "implementer" and IMPLEMENTER_MUST_NOT in instructions:
            failures.append("implementer: orchestrator merge-if-ready sentence leaked into the TOML")
        if role in WORKERS:
            md_items = [normalize_emphasis(item) for item in markdown_do_not(md_text)]
            toml_items = [normalize_emphasis(item) for item in toml_do_not(instructions)]
            if not md_items:
                failures.append(f"{role}: markdown brief missing ## Do NOT items")
            elif len(md_items) > MAX_DO_NOT:
                failures.append(f"{role}: ## Do NOT has {len(md_items)} items; at most {MAX_DO_NOT}")
            elif md_items != toml_items:
                failures.append(f"{role}: Do NOT items differ after stripping backticks and bold")
                failures.append(f"  md={md_items}")
                failures.append(f"  toml={toml_items}")
        if role == "reviewer":
            # The script stays until PR 4. The brief no longer names it.
            # The read-only tools line is still the same allowlist.
            script = (ROOT / "core/scripts/run-isolated-review.sh").read_text()
            allowed = reviewer_allowed_tools(script)
            tools = frontmatter_tools(md_text)
            if not tools or any(token in tools for token in ("Edit", "Write", "MultiEdit")):
                failures.append(f"reviewer: tools frontmatter is not read-only: {tools!r}")
            elif allowed and tools != allowed:
                failures.append(
                    f"reviewer: tools frontmatter {tools!r} != REVIEWER_ALLOWED_TOOLS {allowed!r}"
                )
            if 'sandbox_mode = "read-only"' not in toml_path.read_text():
                failures.append('reviewer: sandbox_mode = "read-only" missing from the TOML')
        for line in normative_lines(md_text):
            missing = [token for token in keywords(line) if token not in lowered and token not in normalized]
            # A paraphrase may drop a function word. Require the concrete tokens
            # (code spans and the longer words) so a new prohibition in the brief
            # fails this check until the TOML covers it.
            if missing:
                failures.append(
                    f"{role}: TOML does not cover brief line {line.strip()!r}; missing {missing}"
                )
    if failures:
        print(f"fail={len(failures)}")
        for item in failures:
            print(item)
        return 1
    print(f"pass={len(ROLES)} codex agent briefs cover their markdown rules")
    return 0


if __name__ == "__main__":
    sys.exit(main())
