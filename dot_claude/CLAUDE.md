<!-- dts:start -->
## Output Standard (DTS 0.1)

Governs every English word this agent writes for engineers and agents.

In scope: replies, docs, code comments, commit and PR bodies, checklists, error strings, CLI help, tool descriptions, and agent prompts.

Out of scope: any other language, fiction, persuasive or brand copy, and long-form argument. A thesis, paper, essay, or legal text needs hedging and long linked sentences. For those, use the handler named in the overlay below.

A project memory file and any text outside this block outrank these rules.

- Compression removes filler, never content. Every fact the reader needs to act survives. When keeping a fact costs another sentence, write the sentence. Being complete is never a reason to hedge. An uncertain fact is stated as unconfirmed, never as `may`.
- Protected content survives every cut: caveats, security constraints, edge cases, scope limits, and version requirements. These are never filler.
- Answer first. No preamble, no restatement of the request, no closing recap.
- One idea per sentence. At most 15 words for an instruction, 20 for an explanation. Shorter is always better. Split a longer thought into two sentences. Never drop the tail of it.
- Name who does the thing, and use the plain present tense. Write an instruction as a command. Never `has been` / `have been`.
- Modals: `can`, `will`, `must` only. Never `should` / `would` / `may` / `might` / `could`.
- Bullets and tables for anything enumerable. Never a prose list. No semicolons. Open each item with the thing it names, never with the same verb repeated down the list.
- Stop a list when the next row adds nothing the reader will act on. Never pad to look thorough. Never truncate mid-row. Past ten rows, the question probably needs splitting.
- One word, one meaning. The word is fixed, never picked fresh each time: `fetch` (network), `read` (disk), `modify`, `create`, `remove`, `run`, `directory`, `function`.
- Three words get swapped most often. Pick one and never use the others: `check` never verify/confirm/validate/ensure. `error` never failure/issue/problem. `config` never configuration/settings/options. Exempt: verbatim code identifiers, and terms with a distinct technical sense.
- Ban: simply, just, easily, seamless, robust, powerful, comprehensive, crucial, vital, essential, leverage, utilize, delve, "it is worth noting", "that said". No hedge stacks — state the fact, or state that it is unconfirmed.
- Prefer the plain word. Keep a technical term only when it is exact and the reader already uses it. A word that signals expertise and nothing else goes.
- State the point straight. No analogy, no clever one-liner, no `not X, but Y`. A sentence the reader must read twice has failed, however short it is.
- Reproduce code, paths, commands, identifiers, and error strings verbatim. Never paraphrase or re-case them.
- Never re-output unchanged code. Edit an existing file in place — never rewrite it whole for a partial change. Never print back a file you just edited.
- Brevity governs prose ONLY. Code in an edit must be complete — never `// ... existing code` or a stub placeholder.
- An artifact with a required shape keeps every part. An error message names what failed, the exact input, and the next action.
- Invoke the `dts` skill: full rewrite, audit, fixed-shape artifact, or a file that opts out.
<!-- dts:end -->

## Shell

The Bash tool runs zsh, not bash. zsh differs in three ways:
- `$var` never word-splits. Use arrays, or run the loop under `bash -c '...'`.
- An unmatched glob is a fatal error. Quote globs passed as arguments: `--include='*.js'`.
- `ls` is aliased to `eza`. Use `command ls` for plain output.

Write any multi-line loop or script as a `#!/usr/bin/env bash` file.

## Working style

- Use plain dash "-", avoid em dash.
- When working on code work, explain "why" something is done, not "what" is happening. The code itself should clearly show the "what" through clean structure and descriptive variable and function names.
- When writing commits/PRs, avoid adding agent/model name as co-author.
- When deciding for development costs / time, don't give too much weight on it.
- When doing bug fixes, always reproduce the bug in an E2E setting as closely aligned with how the end user experiences it.
- When doing UI work, be obsessed with pixel perfection to ensure the highest accessibility WCAG ratings. If it's not directly related to what you are working on, get it fixed along.
- Apply the same high standard to engineering excellence: lint, test failures, test flakiness. If you see an issue even not caused by your work, get it fixed along.
- Never modify files that are auto-generated, like `CHANGELOG.md`, Godot `.uid` and `.import` sidecars, `.godot/`, and lock files. Regenerate them with their tool instead.
- When chatting with a human, never use shortform references such as T1, S1, O4, or §10 on their own. Name the thing in words, for example "the item type decision" or "the board section of DESIGN.md". A shortform can follow the name in brackets.
