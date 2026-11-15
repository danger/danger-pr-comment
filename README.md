# Danger PR Comment

[![Test](https://github.com/danger/danger-pr-comment/actions/workflows/test.yml/badge.svg)](https://github.com/danger/danger-pr-comment/actions/workflows/test.yml)
[![Coverage Status](https://coveralls.io/repos/github/danger/danger-pr-comment/badge.svg?branch=main)](https://coveralls.io/github/danger/danger-pr-comment?branch=main)

Reusable GitHub Actions workflows for running Danger and posting a PR comment from a JSON report.

## Table of Contents

- [Usage](#usage)
  - [Prerequisites](#prerequisites)
  - [Quick Install](#quick-install)
  - [Manual Setup](#manual-setup)
- [Implementation Details](#implementation-details)
  - [Stacked PR Targets](#stacked-pr-targets)
  - [JSON Report Output](#json-report-output)
    - [Shared Dangerfile](#shared-dangerfile)
    - [Custom at_exit Hook](#custom-at_exit-hook)
  - [Permissions](#permissions)
  - [Inputs](#inputs)
    - [danger-run.yml](#danger-runyml)
    - [danger-comment.yml](#danger-commentyml)
- [License](#license)

## Usage

### Prerequisites

Setup [Danger](https://github.com/danger/danger) in your repository.

For example, the following `Gemfile` and `Dangerfile` install danger with the [danger-changelog plugin](https://github.com/dblock/danger-changelog).

```ruby
group :development, :test do
  gem 'danger'
  gem 'danger-changelog'
  gem 'danger-pr-comment', require: false
end
```

```
# frozen_string_literal: true

danger.import_dangerfile(gem: 'danger-pr-comment')

changelog.check!
```

Run `bundle install` and `bundle exec danger` to make sure it works.

```bash
bundle exec danger

Could not find the type of CI for Danger to run on.
```

### Quick Install

From your repository root:

```bash
curl -fsSL https://raw.githubusercontent.com/danger/danger-pr-comment/main/scripts/install-workflows.sh | bash
```

Use `--force` to overwrite existing workflow files `.github/workflows/danger.yml` and `.github/workflows/danger-comment.yml`: 

```bash
curl -fsSL https://raw.githubusercontent.com/danger/danger-pr-comment/main/scripts/install-workflows.sh | bash -s -- --force
```

To target a specific directory:

```bash
curl -fsSL https://raw.githubusercontent.com/danger/danger-pr-comment/main/scripts/install-workflows.sh | bash -s -- --root /path/to/repo
```

### Manual Setup

Create `.github/workflows/danger.yml` in your repository:

```yaml
name: Danger
on:
  pull_request:
    types: [opened, reopened, edited, synchronize]

jobs:
  danger:
    uses: danger/danger-pr-comment/.github/workflows/danger-run.yml@v0.2.0
    secrets: inherit
    with:
      ruby-version: '3.4'
      bundler-cache: true
```

Create `.github/workflows/danger-comment.yml` in your repository:

```yaml
name: Danger Comment
on:
  workflow_run:
    workflows: [Danger]
    types: [completed]

permissions:
  actions: read        # download artifacts
  issues: write        # list + create/update comments
  pull-requests: write # PR comment access

jobs:
  comment:
    uses: danger/danger-pr-comment/.github/workflows/danger-comment.yml@v0.2.0
    secrets: inherit
```

## Implementation Details

Using danger-pr-comment solves the problem of needing special permissions to post a PR comment from contributions from forks. This is implemented by producing a JSON report during the PR, and reading the report in a separate workflow.

Comments are sticky: the commenter searches every page of PR comments and updates the first comment authored by `github-actions[bot]` whose body starts with the configured marker on its own line. Comments from people or other bots, quoted markers, and other report markers are left untouched. If no matching comment exists, it creates one.

Writers sharing the caller repository, source repository ID, head branch, and comment marker are serialized without cancelling an in-progress writer. This prevents simultaneous runs for the same PR source from both creating a comment, including for fork contributions. Different markers remain independent. GitHub concurrency does not guarantee execution order; this is not a newest-report selection policy.

By default, the commenter posts even when the report is empty. Set `comment-empty: false` in the commenter job's `with` inputs to avoid creating comments for empty reports. An empty report has no errors, warnings, messages, or markdown; this is independent of whether the Danger command succeeded. Existing report comments are still updated to "No issues found" when findings clear, so previous results do not remain stale.

The commenter only processes successful or failed `pull_request` runs received through `workflow_run`. Reports are untrusted: before listing or writing comments, the commenter checks that the report identifies a positive integer PR number and fetches that PR from the caller's repository. Its current head commit, branch, and repository ID must match the triggering run, and its target branch must match the trusted allowed base. Without provenance, the allowed base is the repository's default branch (or the trusted caller's `base-branch` input). Mismatched reports and PRs whose head repository has been deleted fail before accessing comments. Reports from runs superseded by newer commits are also rejected. No pull request code is checked out or executed by the commenter.

### Stacked PR Targets

For a fixed non-default target, configure `base-branch` in the trusted commenter caller. To follow changing stack targets automatically, opt into attested PR provenance. The fallback becomes **explicit `base-branch` → verified triggering-PR base → repository default branch**. An explicit base remains a hard restriction, including when provenance is enabled.

`workflow_run` is not the original PR event. Its `pull_requests` array and check-suite associations can be empty for forks, and commit-matching API results do not prove which PR triggered a run when PRs share head metadata. Looking up the base of the report's claimed PR would allow the untrusted report to choose its own restriction. Without provenance, the existing static-base/head checks are retained, but do not establish original-trigger identity.

Add a **separate job** to the producer workflow (`Danger` above), alongside the read-only Danger job:

```yaml
  provenance:
    permissions:
      contents: read
      id-token: write
      attestations: write
    uses: danger/danger-pr-comment/.github/workflows/danger-provenance.yml@PRODUCER_COMMIT_SHA
```

In the trusted commenter caller on your default branch, configure the corresponding certificate identity:

```yaml
jobs:
  comment:
    uses: danger/danger-pr-comment/.github/workflows/danger-comment.yml@COMMENTER_COMMIT_SHA
    secrets: inherit
    with:
      provenance-signer: https://github.com/danger/danger-pr-comment/.github/workflows/danger-provenance.yml@PRODUCER_COMMIT_SHA
```

Replace the placeholder SHAs with full trusted commit SHAs containing these workflows. The producer's `uses` ref and the signer identity must use the **same** producer commit. Do not select either from PR data or trust a general-purpose attester that signs caller-supplied metadata. Keep the Danger job's existing read-only permissions; grant the signing permissions only to the separate metadata job.

The metadata-only producer captures the original GitHub PR number, head and base, repository ID, workflow run ID, and attempt. It signs `provenance.json` with GitHub's official attestation action and uploads it with `provenance.sigstore.json` in `danger-pr-provenance-<attempt>` in the same run as the report. It neither downloads reports nor checks out or executes PR code. The commenter uses the hosted runner's `gh attestation verify --bundle` to check the file digest, exact signer identity, GitHub OIDC issuer, SLSA predicate, and GitHub-hosted runner policy, then validates the signed snapshot against the triggering run and live PR before any comment access. Bundle verification avoids an attestations API lookup and does not require adding `attestations: read` to commenter callers. The PR number in the report must equal the signed number, even if another PR shares every head field. Signed repository IDs are also checked, rather than relying only on certificate repository names. OIDC bearer tokens are not uploaded.

Once `provenance-signer` is set, proof is required for **all** targets, including the default branch and explicit `base-branch` targets. Missing, invalid, inaccessible, wrong-run/attempt, or conflicting proof fails closed, without falling back to API associations or the default branch. If a lower PR merges and GitHub retargets the upper PR, a report for the old base is rejected. Trigger a fresh PR-event run (`edited` is included in the example above); rerunning the old event retains its old base snapshot. Base-branch commit advancement alone is not a retarget: the base repository and branch, not its tip SHA, are bound.

Attested provenance currently supports GitHub.com and requires artifact-attestation availability for the repository's plan ([GitHub documentation](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations)). Fork PRs normally cannot receive the signing/write permissions needed to generate proof; automatic non-default targets therefore cannot be promised for forks. Do **not** enable write tokens for fork builds to work around this. Missing proof is rejected; callers that cannot produce proof can keep using the existing default or explicitly configured base without opting in. Existing callers and the installer remain unchanged.

### JSON Report Output

Your Dangerfile must write a JSON report to `ENV['DANGER_REPORT_PATH']`.

#### Shared Dangerfile

```ruby
# Import danger-pr-comment for automatic danger report export to JSON
danger.import_dangerfile(gem: 'danger-pr-comment')
```

See [Dangerfile](Dangerfile) for implementation details.

#### Custom `at_exit` Hook

```ruby
# Dangerfile
require 'json'
require 'English'

dangerfile_instance = self if defined?(Danger::Dangerfile) && is_a?(Danger::Dangerfile)
at_exit do
  next if $ERROR_INFO && !$ERROR_INFO.is_a?(SystemExit)
  next unless dangerfile_instance

  report_path = ENV.fetch('DANGER_REPORT_PATH', nil)
  event_path = ENV.fetch('GITHUB_EVENT_PATH', nil)
  next unless report_path && event_path && File.exist?(event_path)

  event = JSON.parse(File.read(event_path))
  pr_number = event.dig('pull_request', 'number')
  next unless pr_number

  to_messages = lambda do |items|
    Array(items).map { |item| item.respond_to?(:message) ? item.message : item.to_s }
  end

  report = {
    pr_number: pr_number,
    errors: to_messages.call(dangerfile_instance.status_report[:errors]),
    warnings: to_messages.call(dangerfile_instance.status_report[:warnings]),
    messages: to_messages.call(dangerfile_instance.status_report[:messages]),
    markdowns: to_messages.call(dangerfile_instance.status_report[:markdowns])
  }

  File.write(report_path, JSON.pretty_generate(report))
end
```

### Permissions

The `Danger Comment` workflow requires explicit permissions. Reusable workflows cannot grant permissions to their callers. Required: `actions: read` (download artifacts from the Danger run), `issues: write` and `pull-requests: write` (create/update PR comments).

The optional `Danger PR Provenance` producer additionally requires `contents: read`, `id-token: write`, and `attestations: write` in its separate caller job. The commenter does not need these signing permissions.

### Inputs

#### `danger-run.yml`

- `ruby-version`: Ruby version for `ruby/setup-ruby`. Leave empty to use `.ruby-version`/`.tool-versions`.
- `gemfile`: Gemfile path for Bundler (default `Gemfile`), for example `gemfiles/danger.gemfile`.
- `bundler-cache`: Enable Bundler caching (default `true`).
- `danger-args`: Arguments passed to `bundle exec danger` (default `dry_run`).
- `report-artifact-name`: Artifact name for the report (default `danger-report`).
- `report-file`: Report filename (default `danger-report.json`).

#### `danger-comment.yml`

- `report-artifact-name`: Artifact name to download (default `danger-report`).
- `report-file`: Report filename inside the artifact (default `danger-report.json`).
- `comment-title`: Heading for the PR comment (default `Danger Report`).
- `comment-marker`: Marker string used to update the comment (default `<!-- danger-report -->`).
- `comment-empty`: Create comments for empty reports (boolean, default `true`). Set to `false` to skip creating empty-report comments; existing report comments are always updated.
- `base-branch`: Allowed pull request target branch (defaults to the authenticated triggering base when provenance is enabled, otherwise the repository's default branch). An explicit value is always a hard restriction. Set this in the trusted caller workflow, for example `base-branch: release`; do not derive it from the report artifact.
- `provenance-signer`: Exact certificate identity of the trusted, pinned `danger-provenance.yml` producer (default empty, disabled). Enables mandatory attestation verification and automatic base selection from the authenticated triggering PR. See [Stacked PR Targets](#stacked-pr-targets) for setup and fork limitations.

## License

MIT License. See [LICENSE](LICENSE.txt) for details.
