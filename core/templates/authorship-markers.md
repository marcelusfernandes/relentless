# Authorship markers

Every agent or human comment on issues/PRs that advances workflow state MUST include both:

1. A visible emoji prefix on the first line of the comment body:
   - Agent-authored: `🤖`
   - Human / relayed human decision: `☺️`
2. A machine-readable HTML comment (ignored by GitHub UI, parseable by scripts):

```
<!-- relentless:author=agent -->
```

or

```
<!-- relentless:author=human decider="<name-from-setup>" -->
```

The `decider` name comes from `.relentless/config.json` (`decider.name`), **not** from the GitHub account that posts the comment (accounts may be shared).

The human's answer, or the Claude UserPromptSubmit hook, posts the ☺️ comment with `author=human` and `decider.name`, even though the GitHub account is shared. Agents do not compose that comment themselves.
