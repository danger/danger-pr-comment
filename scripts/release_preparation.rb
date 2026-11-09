# frozen_string_literal: true

require 'ruby-gem-release/changelog'

class ReleaseChangelog < RubyGemRelease::Changelog::KeepAChangelog
  def release!(release)
    updates = workflow_updates(release.version)
    super
    updates.each { |path, text| File.write(path, text) }
  end

  private

  def workflow_updates(version)
    %w[README.md scripts/install-workflows.sh spec/scripts/install_workflows_spec.rb].to_h do |path|
      [path, update_references(File.read(path), version, path)]
    end
  end

  def update_references(content, version, path)
    %w[run comment].reduce(content) do |text, workflow|
      pattern = %r{(danger/danger-pr-comment/\.github/workflows/danger-#{workflow}\.yml@)(?:v\d+\.\d+\.\d+|main)(?=['"\s]|$)}
      raise "Expected exactly one danger-#{workflow} workflow reference in #{path}" unless text.scan(pattern).one?

      text.sub(pattern) { "#{Regexp.last_match(1)}v#{version}" }
    end
  end
end
