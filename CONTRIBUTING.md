# Contributing to FCUK-EM-ALL

Thanks for helping people own their media. This project is shell + Docker Compose
+ a FastAPI/React wizard, and it holds to a few firm standards so that a
one-command install stays reliable across machines.

## Reporting bugs

Open a [bug report](../../issues/new?template=bug_report.md) with:
- OS and version, and how you installed (dmg / one-liner / manual).
- `docker compose version` output.
- The affected service and what you expected vs. what happened.
- Relevant logs — **redact any personal data** (domains, tokens, emails).

## Suggesting features

Open a [feature request](../../issues/new?template=feature_request.md). Describe
the problem first, then your proposed solution and any alternatives you weighed.

## Submitting code

1. **Fork** and create a branch named `feat/<short-name>` or `fix/<short-name>`.
2. Make your change. Keep runtime logic and any build/helper scripts separate.
3. **ShellCheck must pass** on every shell file you touch:
   `shellcheck --severity=warning <file>`. Suppressions need an inline comment
   explaining why.
4. **`bash bootstrap.sh --verify-only` must stay green** (30/30) on a working
   appliance. If your change affects install, also confirm `bash bootstrap.sh
   --dry-run` writes nothing.
5. Prove **both directions**: the positive path *and* the intended failure path
   (a clean, correct error is a passing test).
6. Update docs for any user-facing change.
7. Open a PR and fill in the [pull request template](.github/PULL_REQUEST_TEMPLATE.md).

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org): `type(scope): description`
where `type` is one of `feat`, `fix`, `docs`, `chore`, `refactor`, `style`.
Be specific — never "update stuff."

```
feat(wizard): add storage free-space validation to setup step 2
fix(bootstrap): derive PROOT from script location instead of a hardcoded path
docs(api-keys): add Europeana free-tier signup link
```

## Code standards

- **Shell:** `set -euo pipefail`; four-level logging; a `--dry-run` that writes,
  installs, contacts, and starts nothing; back up any file before editing it;
  idempotent (detect already-applied state and skip). Pin `PATH`. Never hardcode
  a machine path or domain — read it from `config.json`.
- **Heredocs:** unique quoted delimiters (`CONFIG_EOF`, not `EOF`), closing
  delimiter on its own line. Do **not** use triple backticks inside scripts.
- **Secrets:** never printed, never committed. Anything sensitive lives in
  `secrets/` or `*.env`, both gitignored.
- **Wizard:** no TypeScript errors, no `@ts-ignore`.

## What not to contribute

- Secrets, `config.json`, or anything from `secrets/` (the `.gitignore` blocks
  these — do not work around it).
- Numbered build scripts (`[0-9]*.sh`) — those are local execution vehicles, not
  source.
- Floating image tags — images are pinned by digest in `pins/`.
- Sources of pirated content, indexer lists, or anything whose purpose is to
  break the law. The `arr` module ships without any preconfigured indexers on
  purpose.

By contributing you agree your work is licensed under [GPL-3.0](LICENSE).
