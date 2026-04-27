## Summary

<!-- 1–3 bullets. What changed, why. -->

## Closes

<!-- Closes #N for each issue this PR resolves. -->

## Test plan

- [ ] ...

## Loop flow

One workflow does everything once this PR is labeled `ready-for-qa`:

1. Reviewer (human or review-handler agent) verifies the work.
2. Reviewer applies `ready-for-qa` label.
3. `.github/workflows/qa-build-test.yml` runs: build + test, then squash-merges the PR, then deploys `main` to Firebase.
4. If build/test fails, the workflow applies `qa-fail` and comments with a run link. Fix and re-label `ready-for-qa` to retry.
