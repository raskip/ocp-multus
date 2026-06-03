## Summary

<!-- What does this change and why? Operator-facing impact in 1-2 sentences. -->

## Type of change

- [ ] Bug fix
- [ ] New feature / capability
- [ ] Docs only
- [ ] Refactor / CI / tooling

## Checklist

- [ ] No secrets or tenant identifiers added (ran `bash scripts/sanitize-check.sh`)
- [ ] Stays generic — placeholders used in docs and `*.tfvars.example`
- [ ] Relevant `docs/` runbook updated
- [ ] `shellcheck` + `bash -n` pass on changed shell scripts
- [ ] `terraform fmt -check` + `terraform validate` pass on changed stacks
- [ ] CI is green

## Notes

<!-- Anything reviewers should know: testing done, follow-ups, risks. -->
