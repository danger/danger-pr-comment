# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'rubygems/package'
require 'rubygems/installer'
require 'rubygems/user_interaction'
require 'tmpdir'
require 'yaml'

RSpec.describe DangerPrComment, :integration do
  let(:workspace) { Dir.mktmpdir('danger-pr-comment-consumer') }
  let(:gem_home) { File.join(workspace, 'gems') }
  let(:environment) do
    {
      'GEM_HOME' => gem_home,
      'GEM_PATH' => ([gem_home] + Gem.path).join(File::PATH_SEPARATOR),
      'PATH' => (([gem_home] + Gem.path).map { |path| Gem.bindir(path) } + [ENV.fetch('PATH')]).join(File::PATH_SEPARATOR),
      'BUNDLE_APP_CONFIG' => File.join(workspace, 'bundle-config'),
      'BUNDLE_USER_CONFIG' => File.join(workspace, 'user-config'),
      'BUNDLE_PATH' => nil,
      'BUNDLE_FROZEN' => nil,
      'BUNDLE_DEPLOYMENT' => nil,
      'DANGER_GITHUB_API_TOKEN' => nil,
      'GITHUB_TOKEN' => nil,
      'GITHUB_EVENT_PATH' => File.join(workspace, 'event.json'),
      'DANGER_REPORT_PATH' => File.join(workspace, 'report.json'),
      'GITHUB_STEP_SUMMARY' => File.join(workspace, 'summary.md'),
      'GIT_CONFIG_NOSYSTEM' => '1',
      'GIT_CONFIG_GLOBAL' => File::NULL
    }.merge(expectations.fetch('environment', {}))
  end

  before { prepare_consumer }
  after { FileUtils.remove_entry(workspace) }

  def root
    File.expand_path('../..', __dir__)
  end

  def build_package
    path = File.join(workspace, 'consumer.gem')
    Dir.chdir(root) do
      Gem::Package.build(Gem::Specification.load('danger-pr-comment.gemspec'), false, false, path)
    end
    path
  end

  def install_package
    Gem::DefaultUserInteraction.use_ui(Gem::SilentUI.new) do
      Gem::Installer.at(build_package, install_dir: gem_home, ignore_dependencies: true).install
    end
  end

  def prepare_consumer
    install_package
    FileUtils.cp_r(Dir.children(scenario).map { |entry| File.join(scenario, entry) }, workspace)
    File.write(File.join(workspace, 'Gemfile'), "source 'https://rubygems.org'\ngem 'danger-pr-comment', '#{described_class::VERSION}'\ngem 'git', '< 6'\n")
    command('bundle', 'install', '--local', '--quiet')
    initialize_repository
  end

  def initialize_repository
    command('git', 'init', '--quiet', '-b', 'main')
    command('git', 'add', '--', *Dir.children(scenario))
    command('git', '-c', 'user.name=Consumer', '-c', 'user.email=consumer@example.test', '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'Initial commit')
  end

  def command(*args, expected_status: 0, stdin_data: nil, env: {})
    stdout, stderr, status = Bundler.with_unbundled_env do
      Open3.capture3(environment.merge(env), *args, chdir: workspace, stdin_data: stdin_data)
    end
    expect(status.exitstatus).to eq(expected_status), "#{args.join(' ')}\n#{stdout}\n#{stderr}"
    [stdout, stderr]
  end

  def consumer_workflow
    fixture = JSON.parse(File.read(File.join(root, 'spec/fixtures/consumer_workflow.json')), symbolize_names: true)
    event = JSON.parse(File.read(File.join(scenario, 'event.json')))
    fixture.fetch(:pr)[:number] = event.dig('pull_request', 'number')
    fixture
  end

  def existing_comments
    path = File.join(workspace, 'comments.json')
    File.exist?(path) ? JSON.parse(File.read(path)) : []
  end

  def comment_input
    consumer_workflow.merge(
      workflow: YAML.load_file(File.join(root, '.github/workflows/danger-comment.yml')),
      inputs: expectations.fetch('comment_inputs', {}),
      reportPath: File.join(workspace, expectations.fetch('comment_report', 'report.json')),
      comments: existing_comments
    )
  end

  def expect_comment
    stdout, = command('node', File.join(root, 'spec/fixtures/publish_consumer_report.js'), stdin_data: JSON.generate(comment_input))
    result = JSON.parse(stdout)
    expect(result).to include(expectations.fetch('comment').merge('failures' => [], 'notices' => [], 'skipped' => false))
    expect(result.fetch('calls')).to start_with('listPulls', 'getPull', 'listComments')
  end

  def expect_report
    path = environment.fetch('DANGER_REPORT_PATH')
    return expect(File).not_to exist(path) unless expectations['report']

    expect(JSON.parse(File.read(path))).to eq(expectations.fetch('report'))
  end

  def expect_preview
    expected = expectations.fetch('preview')
    stdout, stderr = command('bundle', 'exec', 'danger-pr-comment', 'render', 'report.json', expected_status: expected.fetch('status'))
    expect(stdout).to eq(expected.fetch('stdout'))
    if expected['stderr_contains']
      expect(stderr).to include(expected.fetch('stderr_contains'))
    else
      expect(stderr).to eq('')
    end
  end

  def expect_summary
    path = File.join(workspace, 'summary.md')
    return expect(File).not_to exist(path) unless expectations['summary']

    expect(File.read(path)).to eq(expectations.fetch('summary'))
  end

  context 'with producer diff defaults' do
    let(:scenario) { File.join(root, 'spec/fixtures/consumer/empty') }
    let(:expectations) { {} }

    before do
      File.write(File.join(workspace, 'Dangerfile'), <<~RUBY)
        danger.import_dangerfile(gem: 'danger-pr-comment')
        message git.modified_files.to_a.sort.inspect
      RUBY
      %w[fork.txt release.txt].each { |path| File.write(File.join(workspace, path), "original\n") }
      commit_fixture
      common, = command('git', 'rev-parse', 'HEAD')
      command('git', 'checkout', '-b', 'release')
      File.write(File.join(workspace, 'release.txt'), "target-only change\n")
      commit_fixture
      base, = command('git', 'rev-parse', 'HEAD')
      command('git', 'checkout', '-b', 'fork-only', common.strip)
      File.write(File.join(workspace, 'fork.txt'), "contribution\n")
      commit_fixture
      head, = command('git', 'rev-parse', 'HEAD')
      command('git', 'checkout', 'release')
      command('git', '-c', 'user.name=Consumer', '-c', 'user.email=consumer@example.test', '-c', 'commit.gpgsign=false',
              'merge', '--no-ff', 'fork-only', '-m', 'Synthetic PR merge')
      command('git', 'init', '--bare', 'base.git')
      command('git', 'remote', 'add', 'origin', File.join(workspace, 'base.git'))
      command('git', 'push', 'origin', "#{common.strip}:refs/heads/main", "#{base.strip}:refs/heads/release",
              "#{head.strip}:refs/pull/7/head", 'HEAD:refs/pull/7/merge')
      event = { repository: { default_branch: 'main' },
                pull_request: { number: 7, base: { ref: 'release', sha: base.strip }, head: { ref: 'fork-only', sha: head.strip } } }
      File.write(environment.fetch('GITHUB_EVENT_PATH'), JSON.generate(event))
    end

    def commit_fixture
      command('git', 'add', '--', 'Dangerfile', 'fork.txt', 'release.txt')
      command('git', '-c', 'user.name=Consumer', '-c', 'user.email=consumer@example.test', '-c', 'commit.gpgsign=false',
              'commit', '--quiet', '-m', 'Fixture change')
    end

    def producer_workflow
      YAML.load_file(File.join(root, '.github/workflows/danger-run.yml'))
    end

    def producer_inputs(arguments)
      workflow = producer_workflow
      inputs = workflow.fetch('on', workflow[true]).fetch('workflow_call').fetch('inputs')
                       .transform_values { |input| input.fetch('default', '') }
      inputs['danger-args'] = arguments unless arguments.nil?
      inputs
    end

    def producer_fixture(arguments)
      step = producer_workflow.fetch('jobs').fetch('danger').fetch('steps').find { |item| item['id'] == 'danger' }
      {
        event: JSON.parse(File.read(environment.fetch('GITHUB_EVENT_PATH'))), inputs: producer_inputs(arguments), run: step.fetch('run'),
        environment: step.fetch('env').select { |key, _value| key.start_with?('DANGER_LOCAL_') }
      }
    end

    def render_producer(arguments)
      stdout, = command('node', File.join(root, 'spec/fixtures/render_producer_workflow.js'), stdin_data: JSON.generate(producer_fixture(arguments)))
      JSON.parse(stdout)
    end

    def run_producer(arguments: nil)
      rendered = render_producer(arguments)
      command('bash', '-e', '-c', rendered.fetch('run'), env: rendered.fetch('environment'))
      JSON.parse(File.read(environment.fetch('DANGER_REPORT_PATH')))
    end

    it 'analyzes a fork against a non-default target rather than the synthetic merge' do
      remote_heads, = command('git', 'ls-remote', '--heads', 'origin')
      expect(remote_heads).not_to include('fork-only', 'refs/heads/master')

      expect(run_producer.fetch('messages')).to eq(['["fork.txt"]'])
      expect(File.read(environment.fetch('GITHUB_STEP_SUMMARY'))).to include('fork.txt')
    end

    it 'preserves explicit diff arguments and custom Dangerfile paths' do
      FileUtils.cp(File.join(workspace, 'Dangerfile'), File.join(workspace, 'CustomDangerfile'))

      report = run_producer(arguments: 'dry_run --dangerfile=CustomDangerfile --base=release --head=release')

      expect(report.fetch('messages')).to eq(['[]'])
    end

    %w[main master].each do |branch|
      it "uses the #{branch} repository default when PR endpoints are absent" do
        command('git', 'update-ref', "refs/remotes/origin/#{branch}", 'main')
        other_branch = branch == 'main' ? 'master' : 'main'
        command('git', 'update-ref', "refs/remotes/origin/#{other_branch}", 'release')
        File.write(environment.fetch('GITHUB_EVENT_PATH'), JSON.generate(repository: { default_branch: branch }, pull_request: { number: 7 }))

        expect(run_producer.fetch('messages')).to eq(['["fork.txt", "release.txt"]'])
      end
    end
  end

  Dir[File.expand_path('../fixtures/consumer/*/expectations.yml', __dir__)].each do |path|
    context File.basename(File.dirname(path)).tr('-', ' ') do
      let(:scenario) { File.dirname(path) }
      let(:expectations) { YAML.safe_load_file(path, aliases: true) }

      it 'exports, previews, summarizes, and comments according to the scenario' do
        command('bundle', 'exec', 'danger', 'dry_run', '--base=HEAD', '--head=HEAD',
                expected_status: expectations.fetch('danger_status'))
        expect_report
        expect_preview
        expect_summary
        expect_comment if expectations['report']
      end
    end
  end
end
