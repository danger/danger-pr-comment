# Releasing

Releases use [ruby-gem-release](https://github.com/dblock/ruby-gem-release) and [RubyGems Trusted Publishing](https://guides.rubygems.org/trusted-publishing/#using-reusable-workflows) through GitHub Actions OIDC. No stored RubyGems API key or manual OTP is required.

The development dependency and reusable workflow are pinned to `ruby-gem-release` 0.4.0.

## One-time setup

1. In **Settings > Environments**, create an environment named `release` and restrict deployments to `main`. To restrict publication to release maintainers, add `numbata` and `dblock` as required reviewers and disable administrator bypass. Leave **Prevent self-review** unchecked to allow a maintainer to dispatch and approve their own release; enable it if a second maintainer must approve. Configure these protections before relying on maintainer-only publication.
2. As a gem owner, open [Trusted publishers](https://rubygems.org/gems/danger-pr-comment/trusted_publishers) on RubyGems.org. Configure repository owner `danger`, repository name `danger-pr-comment`, workflow filename `release.yml`, and environment `release`. Set the separate **workflow repository** fields to owner `dblock` and repository `ruby-gem-release`. Existing publishers must be updated for the reusable workflow; the old standalone-workflow configuration is not sufficient. Use the actual caller owner and repository when publishing from another repository; forks are not automatically trusted.
3. Ensure branch rules allow the Actions bot to push release preparation and the next development version directly to `main`.

The caller grants `contents: write` and `id-token: write` to the reusable workflow and runs only on `main`. The reusable workflow uses the `release` environment, authenticates through OIDC, and serializes releases. Repository writers can dispatch or rerun the workflow, but required environment reviewers control approval before the release job starts. Without required reviewers, repository writers can publish without maintainer approval. Repository variables are not an independent authorization boundary because writers can edit them.

After verifying trusted publishing works, remove any obsolete `RUBYGEMS_API_KEY` repository secret and revoke its RubyGems API key if it is no longer used elsewhere.

## Prepare and publish

Start from current `main`, review changes since the last release, and maintain nonempty release notes under `## [Unreleased]` in `CHANGELOG.md`. The previous release increments `lib/danger-pr-comment/version.rb` to the next patch version, so a normal patch release needs no manual version change.

Run the [Release workflow](https://github.com/danger/danger-pr-comment/actions/workflows/release.yml) on `main`, or use:

```sh
gh workflow run release.yml --ref main                  # release the version in version.rb
gh workflow run release.yml --ref main -f version=0.3.0 # release an explicit version
```

The optional `version` input retains its existing behavior: the library's standard preparation writes the requested MAJOR.MINOR.PATCH version before the reusable workflow verifies it against the prepared gemspec. The version must be absent from RubyGems and its release tag must not already exist. Unpublished maintenance versions below the latest release are allowed; there is no version-ordering restriction. A required reviewer must approve the deployment when the `release` environment has approval protection.

The Rakefile installs `ruby-gem-release`'s standard gem workflow without custom task or command overrides. A small Keep a Changelog subclass updates the README, installer, and installer specs to `@vVERSION`, validating every workflow reference before writing release files. Changelog formatting and empty-note validation remain delegated to the library. Do not manually date the changelog or update those references.

The reusable workflow rejects stale dispatches, stages preparation, rejects existing tags and published RubyGems versions, and runs `bundle exec rake` against the prepared release. It commits preparation, builds and verifies the gem, creates a local tag and recovery bundle, publishes to RubyGems, then atomically pushes the prepared commit and tag. It creates a GitHub release with the gem attached, then increments the patch version, opens a fresh `[Unreleased]` section, and pushes the next development iteration. The README and installer continue referencing the published release.

Publishing before updating `main` and the tag keeps the installer on an existing published workflow tag. Concurrent changes to `main` reject ref updates instead of overwriting them. The automatic `GITHUB_TOKEN` is sufficient, but its pushes do not trigger push-based workflows; validation runs explicitly during release.

## Verify

Check the exact published version, tag, GitHub release, and next development version:

```sh
curl --fail https://rubygems.org/api/v2/rubygems/danger-pr-comment/versions/0.3.0.json
git ls-remote --tags origin 'v0.3.0*'
gh release view v0.3.0
git pull --ff-only origin main
cat lib/danger-pr-comment/version.rb
```

## Recover from a failed release

Check which steps succeeded before retrying. RubyGems versions cannot be overwritten, and published tags must not be moved. See the upstream [recovery instructions](https://github.com/dblock/ruby-gem-release/blob/v0.4.0/RELEASING.md#verify-and-recover) for the full procedure.

The reusable workflow preserves available artifacts even after publication fails, under `release-gem-VERSION-RUN_ID-RUN_ATTEMPT`: `release.gem`, its SHA-256 manifest `release.json`, and `release.bundle` containing the exact prepared commit and tag.

* Before publication: fix the failure and dispatch a fresh run. Preparation has not changed `main` or pushed a tag. If an upload failed or timed out, check RubyGems first; the server may have accepted it.
* Gem published, atomic push failed: download the original run's recovery artifact with `gh run download RUN_ID --name release-gem-VERSION-RUN_ID-RUN_ATTEMPT`. Verify the gem and manifest, recover the original tag with `git fetch ./release.bundle refs/tags/vVERSION:refs/tags/vVERSION`, and reconcile any newer commits before pushing the exact release commit and tag. Never force-push `main`, move the release tag, or tag a different commit as the published gem.
* Tag pushed, GitHub release missing: use `gh release create vVERSION --verify-tag --generate-notes`, attaching the recovered original gem.
* Release complete, next iteration failed: pull current `main`, resolve branch permissions or concurrent changes, and increment the version and open `[Unreleased]` only if those changes have not already occurred. Commit and push the missing preparation without publishing again.

Do not rerun the entire workflow after publication to repair a missing tag, release, or version bump. Complete only the missing steps.

If OIDC fails, verify both the caller and reusable-workflow repository fields, workflow filename, environment, and `id-token: write`. Do not add a long-lived API key as a workaround.

## Manual publishing

Trusted publishing authenticates GitHub Actions, not a local shell. Prefer the release workflow. For an exceptional local release, authenticate with your RubyGems account and complete MFA. Start from clean, current `main`, set the release context environment variables documented in [Tasks](https://github.com/dblock/ruby-gem-release/blob/v0.4.0/docs/tasks.md), and use `release:before_release`, validation, `release:publish`, and `release:after_release` in that order. Keep one shared `RUNNER_TEMP` directory across these commands so preparation snapshots and recovery artifacts persist. Publication tasks perform real remote writes; never use them as a preview. The old `scripts/release_version.rb` commands have been replaced by these tasks.
