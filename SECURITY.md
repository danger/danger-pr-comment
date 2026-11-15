# Security

The commenter treats uploaded reports as untrusted and checks GitHub before deciding where to post. It checks the PRs that exist **now**, not a signed record of which PR originally started the run.

## What's the Worst That Can Happen?

**Someone could make Danger post a misleading report on another matching PR, or replace its existing Danger comment with a fake "all clear."** The destination must still be an open PR in the caller repository with the exact source repository, branch, and commit from the run, and an allowed target branch. It cannot be just any unrelated PR.

For example, PRs A and B could use the same source branch and commit but target different branches. Danger runs for A. If A closes before the comment is posted, someone who controls the uploaded report could change its PR number to B. B could then pass the checks, even if the original workflow would not normally run for B's target branch.

An old report can also be posted after a PR changes its target branch without changing its code, or overwrite a newer report from another run at the same commit. That can make the current PR look checked when its current target was not. Run Danger again after changing the target, but this version cannot guarantee that happened.

These are risks to the accuracy of the PR comments. This workflow does not merge PRs, change code, or execute code from the uploaded report. **Do not rely on current-state matching to prove which PR or target originally triggered the run.**

## Allowed Target Branches

The `base-branch` input controls the allowed **current** target:

| Value | Policy |
| --- | --- |
| Omitted or empty | Repository default branch |
| `release` | Exactly `release` |
| `"*"` | Explicitly allow any target branch in the caller repository |

For upper stacked PRs whose parent branch can change, opt in from the trusted commenter caller:

```yaml
    with:
      base-branch: "*"
```

Non-default-target callers must set a literal allowed branch or `"*"`. Even an explicit literal base cannot break a tie between multiple same-head PRs on different bases. A literal base restricts the current destination; it does not prove original-trigger identity. Neither a claimed base nor any other field from the report controls the lookup or base policy.

## How Matching Works

The commenter processes only successful or failed `pull_request` runs delivered through `workflow_run`. It independently lists open PRs using the run's source owner and branch, follows every page, and matches the exact head SHA, head branch, source repository ID, and caller base repository ID. There must be exactly one matching open PR **across all bases**, before applying any base-branch policy. The report's positive safe-integer `pr_number` must equal that independently resolved number; it cannot select among ambiguous candidates.

The commenter fetches the resolved PR again and rechecks its number, open state, head, and allowed current base before listing or writing comments. Its creation timestamp must be valid and no later than the original workflow run's creation timestamp, not a later rerun start time. Missing run metadata, deleted forks, stale heads, ambiguous or absent matches, missing allowed bases, and API errors fail before any comment access.

Fork PRs use the same read-only API lookup and do not require populated `workflow_run.pull_requests` arrays or additional producer permissions. This uses the existing commenter permissions; it adds no producer job, signing permissions, or PR checkout/execution.

## Other Limitations

- Retargeting without changing the head can leave an older report eligible if the new current base is allowed. A fresh event-triggered run is recommended after retargeting, including after lower stacked PRs merge, but freshness cannot be reliably enforced without an original base snapshot.
- Closed or merged PRs and multiple same-head open PRs are skipped/rejected. A PR with a creation timestamp after the original run is rejected, but timestamps are only a coarse guard, not identity proof.
- API inconsistency, inaccessible metadata, or source-owner changes can cause conservative rejection. The commenter does not fall back to the artifact's PR number when lookup fails.
- Same-head reruns and delayed reports do not establish original-attempt identity or newest-result ordering. Existing writer concurrency only prevents simultaneous writers; GitHub does not guarantee execution order.

[Back to the README](README.md)
