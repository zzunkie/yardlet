---
name: writing-skills
description: Use when creating or improving a Yardlet-compatible skill through the existing skill authoring and review workflow
---

# Writing Yardlet Skills

## Scope

Create one focused, reusable procedure. Use Yardlet's configured skill author,
evaluator, and review tasks. Do not create a second dispatcher or bypass the
canonical skill apply path.

## Required Structure

Each skill is a directory whose name exactly matches the frontmatter `name`.
Its entry file is `SKILL.md` and begins with YAML frontmatter containing:

- `name`: lowercase kebab-case, equal to the directory name;
- `description`: one sentence that says when the skill applies and what it helps do.

The Markdown body must explain purpose, triggers, bounded steps, failure or stop
conditions, and verification. Link only relative files bundled in the same
skill directory.

## Authoring Procedure

1. Confirm the recurring problem and evidence that a reusable procedure is needed.
2. Search the active skill catalog and avoid duplicating an existing skill.
3. Write the smallest procedure that changes future behavior.
4. Put detailed reference material in relative companion files only when needed.
5. List every bundled script or asset and its runtime requirements.
6. Check the whole directory for network, credential, tool, and external-mutation instructions.
7. Draft through `yardlet skill research` or `yardlet skill create` as appropriate.
8. Install only through the deterministic `yardlet skill apply` path.
9. Evaluate the installed skill on representative tasks and request an independent review task.

## Writing for Compliance

Use direct, imperative steps and explain why constraints matter. The techniques
in [persuasion-principles.md](persuasion-principles.md) can help make a skill
resistant to shortcut rationalizations without adding tool dependencies.

## Safety

A skill may describe that a gated capability exists, but it cannot grant that
capability. Any network, credential, browser, remote-write, deployment, or
other external mutation remains subject to the task contract and existing
Yardlet gates at use time.

## Verification Checklist

- [ ] Directory name and frontmatter name match.
- [ ] Description is a specific trigger, not a generic summary.
- [ ] All relative links resolve inside the skill directory.
- [ ] Bundled inventory is explicit and minimal.
- [ ] No undeclared runtime requirement or external mutation instruction remains.
- [ ] The existing author, evaluator, apply, and review paths are used.
