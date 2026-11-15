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

Before commenting, the workflow looks for one open PR matching the run's source repository, branch, and commit, then checks its current target. This reduces misdirected comments but does not prove which PR originally triggered the run. See [Security](SECURITY.md) for the worst-case risks, detailed checks, and stacked-PR setup.

Comments are sticky: the commenter searches every page of PR comments and updates the first comment authored by `github-actions[bot]` whose body starts with the configured marker on its own line. Comments from people or other bots, quoted markers, and other report markers are left untouched. If no matching comment exists, it creates one.

Writers sharing the caller repository, source repository ID, head branch, and comment marker are serialized without cancelling an in-progress writer. This prevents simultaneous runs for the same PR source from both creating a comment, including for fork contributions. Different markers remain independent.

By default, the commenter posts even when the report is empty. Set `comment-empty: false` in the commenter job's `with` inputs to avoid creating comments for empty reports. An empty report has no errors, warnings, messages, or markdown; this is independent of whether the Danger command succeeded. Existing report comments are still updated to "No issues found" when findings clear, so previous results do not remain stale.

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
- `base-branch`: Allowed current PR target (default: repository default branch). A literal value is a hard restriction; `"*"` explicitly allows changing stacked targets within the caller repository. Configure this in the trusted caller, not from report data. See [Security](SECURITY.md#allowed-target-branches) for details.

## License

MIT License. See [LICENSE](LICENSE.txt) for details.
