<!-- Thanks for contributing! Fill this out so review is quick. -->

## Type of change
- [ ] `feat` — new capability
- [ ] `fix` — bug fix
- [ ] `docs` — documentation only
- [ ] `refactor` — no behavior change
- [ ] `chore` — tooling / maintenance
- [ ] `style` — formatting / lint only

## Description
What does this change and why?

## Testing done
How did you verify it — both the positive path and the intended failure path?

## Checklist
- [ ] `bash bootstrap.sh --dry-run` writes/installs/starts nothing
- [ ] `bash bootstrap.sh --verify-only` is green (30/30) on a working appliance
- [ ] Verified **both directions** (positive + planned negative; a clean failure is a pass)
- [ ] No secrets, `config.json`, or `secrets/` contents added
- [ ] No numbered build scripts (`[0-9]*.sh`) added
- [ ] `shellcheck --severity=warning` passes on every shell file I touched
- [ ] Docs updated for any user-facing change
- [ ] Commits follow Conventional Commits (`type(scope): description`)
