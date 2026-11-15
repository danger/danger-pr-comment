# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'ruby-gem-release/release'
require_relative '../../scripts/release_preparation'

RSpec.describe ReleaseChangelog do
  let(:release) { RubyGemRelease::Release.new(version: '1.2.3', gemspec_version: '1.2.3', date: Date.new(2026, 11, 8)) }
  let(:changelog) { described_class.new }
  let(:workflow_paths) { %w[README.md scripts/install-workflows.sh spec/scripts/install_workflows_spec.rb] }

  def root
    File.expand_path('../..', __dir__)
  end

  def with_release_files
    Dir.mktmpdir do |directory|
      workflow_paths.each do |path|
        FileUtils.mkdir_p(File.dirname("#{directory}/#{path}"))
        FileUtils.cp("#{root}/#{path}", "#{directory}/#{path}")
      end
      File.write("#{directory}/CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- A fix.\n\n## [0.1.0] - 2024-01-01\n")
      Dir.chdir(directory) { yield directory }
    end
  end

  def release_files
    Dir.glob('**/*').select { |path| File.file?(path) }.to_h { |path| [path, File.read(path)] }
  end

  it 'updates both workflow references in the README, installer and installer specs' do
    with_release_files do
      changelog.release!(release)
      workflow_paths.each do |path|
        %w[run comment].each do |workflow|
          expect(File.read(path)).to include("danger-#{workflow}.yml@v1.2.3")
        end
      end
    end
  end

  it 'rejects missing or duplicate workflow references before writing any files' do
    with_release_files do
      path = 'spec/scripts/install_workflows_spec.rb'
      content = File.read(path)
      [content.gsub('danger-comment.yml', 'other.yml'), "#{content}\n#{content}"].each do |invalid|
        File.write(path, invalid)
        original = release_files
        expect { changelog.release!(release) }.to raise_error(/Expected exactly one/)
        expect(release_files).to eq(original)
      end
    end
  end

  it 'leaves workflow references unchanged if changelog preparation fails' do
    with_release_files do
      File.write('CHANGELOG.md', "## [Unreleased]\n\n## [0.1.0] - 2024-01-01\n\n- Older changes.\n")
      original = release_files.slice(*workflow_paths)
      expect { changelog.release!(release) }.to raise_error(ArgumentError)
      expect(release_files.slice(*workflow_paths)).to eq(original)
    end
  end
end
