# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'yaml'

RSpec.describe 'Danger Comment workflow' do
  let(:workflow) { YAML.load_file(File.expand_path('../../.github/workflows/danger-comment.yml', __dir__)) }
  let(:run) do
    {
      event: 'pull_request',
      conclusion: 'success',
      id: 123,
      run_attempt: 1,
      head_sha: 'abc123',
      head_branch: 'contribution',
      head_repository: { id: 42 }
    }
  end
  let(:pr) do
    {
      head: { sha: 'abc123', ref: 'contribution', repo: { id: 42 } },
      base: { ref: 'main', repo: { id: 1 } }
    }
  end

  let(:fixture) do
    job = workflow.fetch('jobs').fetch('comment')
    step = job.fetch('steps').last
    {
      condition: job.fetch('if'),
      script: step.fetch('with').fetch('script'),
      context: {
        eventName: 'workflow_run',
        payload: { workflow_run: run, repository: { id: 1, default_branch: 'main' } },
        repo: { owner: 'danger', repo: 'example' },
        serverUrl: 'https://github.com'
      },
      environment: step.fetch('env'),
      verification: job.fetch('steps').find { |item| item['id'] == 'verify_provenance' },
      inputs: workflow.fetch('on', workflow[true]).fetch('workflow_call').fetch('inputs')
                      .transform_values { |input| input.fetch('default', '') },
      report: { pr_number: 7 },
      pr: pr,
      comments: [],
      apiError: false
    }
  end

  def execute_workflow(**overrides)
    harness = File.expand_path('../fixtures/run_comment_workflow.js', __dir__)
    stdout, stderr, status = Open3.capture3('node', harness, stdin_data: JSON.generate(fixture.merge(overrides)))
    raise "Node workflow harness failed: #{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  def producer_fixture(proof)
    step = YAML.load_file(File.expand_path('../../.github/workflows/danger-provenance.yml', __dir__))
               .fetch('jobs').fetch('provenance').fetch('steps').first
    {
      script: step.fetch('with').fetch('script'), environment: step.fetch('env'),
      context: { runId: 123, runAttempt: 1, payload: { repository: { id: 1 }, pull_request: proof.fetch(:pull_request) } }
    }
  end

  it 'posts a report for a matching fork pull request' do
    result = execute_workflow

    expect(result.fetch('failures')).to be_empty
    expect(result.fetch('calls').first).to include('method' => 'get', 'owner' => 'danger', 'repo' => 'example', 'pull_number' => 7)
    expect(result.fetch('calls').last).to include('method' => 'createComment', 'issue_number' => 7)
  end

  it 'updates an existing comment for a matching failed pull request run' do
    run[:conclusion] = 'failure'
    result = execute_workflow(comments: [{ id: 10, user: { login: 'github-actions[bot]', type: 'Bot' }, body: "<!-- danger-report -->\nOld report" }])

    expect(result.fetch('failures')).to be_empty
    expect(result.fetch('calls').last).to include('method' => 'updateComment', 'comment_id' => 10)
  end

  it 'accepts a matching pull request from the base repository' do
    run[:head_repository][:id] = 1
    pr[:head][:repo][:id] = 1

    expect(execute_workflow.fetch('calls').last).to include('method' => 'createComment')
  end

  it 'allows a trusted caller to select another base branch' do
    pr[:base][:ref] = 'release'
    fixture[:inputs]['base-branch'] = 'release'
    result = execute_workflow

    expect(result.fetch('failures')).to be_empty
    expect(result.fetch('calls').last).to include('method' => 'createComment')
  end

  [nil, 0, -1, 1.5, true, '7', 9_007_199_254_740_992].each do |pr_number|
    it "rejects an invalid PR number #{pr_number.inspect} before making API calls" do
      result = execute_workflow(report: { pr_number: pr_number })

      expect(result.fetch('failures')).not_to be_empty
      expect(result.fetch('calls')).to be_empty
    end
  end

  it 'rejects a forged report pointing at another pull request' do
    pr[:head][:repo][:id] = 43
    result = execute_workflow(report: { pr_number: 8 })

    expect(result.fetch('failures')).not_to be_empty
    expect(result.fetch('calls')).to contain_exactly(
      include('method' => 'get', 'pull_number' => 8)
    )
  end

  {
    'commit' => ->(pr) { pr[:head][:sha] = 'different' },
    'branch' => ->(pr) { pr[:head][:ref] = 'different' },
    'repository' => ->(pr) { pr[:head][:repo][:id] = 43 },
    'base branch' => ->(pr) { pr[:base][:ref] = 'release' },
    'deleted fork' => ->(pr) { pr[:head][:repo] = nil }
  }.each do |name, change|
    it "rejects a report targeting a PR with a mismatched #{name}" do
      change.call(pr)
      result = execute_workflow

      expect(result.fetch('failures')).not_to be_empty
      expect(result.fetch('calls').map { |call| call.fetch('method') }).to eq(['get'])
    end
  end

  it 'rejects a base branch mismatch even when the caller supplies an override' do
    fixture[:inputs]['base-branch'] = 'release'
    result = execute_workflow

    expect(result.fetch('failures')).not_to be_empty
    expect(result.fetch('calls').map { |call| call.fetch('method') }).to eq(['get'])
  end

  %i[head_sha head_branch head_repository].each do |field|
    it "rejects a run missing #{field}" do
      run[field] = nil
      result = execute_workflow

      expect(result.fetch('failures')).not_to be_empty
      expect(result.fetch('calls').map { |call| call.fetch('method') }).to eq(['get'])
    end
  end

  [nil, 0, '42'].each do |repository_id|
    it "rejects an invalid run repository ID #{repository_id.inspect}" do
      run[:head_repository][:id] = repository_id
      pr[:head][:repo][:id] = repository_id
      result = execute_workflow

      expect(result.fetch('failures')).not_to be_empty
      expect(result.fetch('calls').map { |call| call.fetch('method') }).to eq(['get'])
    end
  end

  it 'fails closed when no allowed base branch can be determined' do
    fixture[:context][:payload][:repository][:default_branch] = ''
    pr[:base][:ref] = ''
    result = execute_workflow

    expect(result.fetch('failures')).not_to be_empty
    expect(result.fetch('calls').map { |call| call.fetch('method') }).to eq(['get'])
  end

  it 'fails without writing comments if the PR cannot be fetched' do
    result = execute_workflow(apiError: true)

    expect(result.fetch('failures')).not_to be_empty
    expect(result.fetch('calls').map { |call| call.fetch('method') }).to eq(['get'])
  end

  context 'with attested PR provenance enabled' do
    let(:provenance) do
      {
        version: 1, repository_id: 1, run_id: 123, run_attempt: 1,
        pull_request: {
          number: 7,
          head: { sha: 'abc123', ref: 'contribution', repo: { id: 42 } },
          base: { ref: 'feature/lower', repo: { id: 1 } }
        }
      }
    end

    before do
      fixture[:inputs]['provenance-signer'] = 'https://github.com/danger/danger-pr-comment/.github/workflows/danger-provenance.yml@trusted-sha'
      fixture[:provenance] = provenance
      pr[:base][:ref] = 'feature/lower'
    end

    it 'allows an upper stacked PR even with empty fork associations' do
      run[:pull_requests] = []
      result = execute_workflow

      expect(result.fetch('failures')).to be_empty
      expect(result.fetch('calls').last).to include('method' => 'createComment', 'issue_number' => 7)
    end

    it 'allows a default-branch PR with verified provenance' do
      provenance[:pull_request][:base][:ref] = 'main'
      pr[:base][:ref] = 'main'

      expect(execute_workflow.fetch('calls').last).to include('method' => 'createComment')
    end

    it 'publishes a matching report from the actual producer capture through verification and commenting' do
      result = execute_workflow(producer: producer_fixture(provenance))

      expect(result.fetch('producedProvenance')).to eq(JSON.parse(JSON.generate(provenance)))
      expect(result.fetch('failures')).to be_empty
      expect(result.fetch('calls').last).to include('method' => 'createComment')
    end

    it 'uses the actual producer script to bind the original event, not the report' do
      result = execute_workflow(producer: producer_fixture(provenance), report: { pr_number: 8 })

      expect(result.fetch('producedProvenance')).to eq(JSON.parse(JSON.generate(provenance)))
      expect(result.fetch('failures')).not_to be_empty
      expect(result.fetch('calls')).to be_empty
    end

    it 'pins the attestation signer, issuer, repository, predicate, and runner policy' do
      arguments = execute_workflow.fetch('verificationArguments')

      expect(arguments.first(2)).to eq(%w[attestation verify])
      expect(arguments.drop(3)).to eq([
                                        '--bundle', arguments[2].sub('provenance.json', 'provenance.sigstore.json'),
                                        '--repo', 'danger/example',
                                        '--cert-identity', fixture[:inputs]['provenance-signer'],
                                        '--cert-oidc-issuer', 'https://token.actions.githubusercontent.com',
                                        '--predicate-type', 'https://slsa.dev/provenance/v1',
                                        '--deny-self-hosted-runners'
                                      ])
    end

    it 'passes a configured signer as one quoted argument' do
      fixture[:inputs]['provenance-signer'] += '; exit 99'
      arguments = execute_workflow.fetch('verificationArguments')

      expect(arguments[arguments.index('--cert-identity') + 1]).to eq(fixture[:inputs]['provenance-signer'])
    end

    it 'does not infer the original trigger from PRs that share a commit' do
      run[:pull_requests] = [{ number: 7 }, { number: 8 }]
      result = execute_workflow

      expect(result.fetch('failures')).to be_empty
      expect(result.fetch('calls').last).to include('method' => 'createComment', 'issue_number' => 7)
    end

    it 'rejects a forged target sharing every head field, even on an allowed base' do
      result = execute_workflow(report: { pr_number: 8 })

      expect(result.fetch('failures')).not_to be_empty
      expect(result.fetch('calls')).to be_empty
    end

    it 'rejects missing provenance even if API associations appear unique' do
      fixture.delete(:provenance)
      run[:pull_requests] = [{ number: 7 }]
      result = execute_workflow

      expect(result.fetch('failures')).not_to be_empty
      expect(result.fetch('calls')).to be_empty
    end

    it 'rejects missing provenance with ambiguous API associations' do
      fixture.delete(:provenance)
      run[:pull_requests] = [{ number: 7 }, { number: 8 }]
      result = execute_workflow

      expect(result.fetch('failures')).not_to be_empty
      expect(result.fetch('calls')).to be_empty
    end

    it 'rejects invalid signatures, inaccessible attestations, or an unexpected signer' do
      result = execute_workflow(verificationExit: 1)

      expect(result.fetch('failures')).not_to be_empty
      expect(result.fetch('calls')).to be_empty
    end

    it 'rejects missing signature bundles without attempting comment access' do
      result = execute_workflow(bundleMissing: true)

      expect(result.fetch('failures')).not_to be_empty
      expect(result.fetch('calls')).to be_empty
    end

    it 'rejects unsupported GitHub hosts before invoking attestation verification' do
      fixture[:context][:serverUrl] = 'https://github.example.com'
      result = execute_workflow

      expect(result.fetch('failures')).not_to be_empty
      expect(result).not_to have_key('verificationArguments')
      expect(result.fetch('calls')).to be_empty
    end

    [nil, [], {}].each do |proof|
      it "rejects a malformed provenance document #{proof.inspect}" do
        result = execute_workflow(provenance: proof)

        expect(result.fetch('failures')).not_to be_empty
        expect(result.fetch('calls')).to be_empty
      end
    end

    {
      'schema' => ->(proof) { proof[:version] = 2 },
      'source repository' => ->(proof) { proof[:repository_id] = 2 },
      'run' => ->(proof) { proof[:run_id] = 124 },
      'run attempt' => ->(proof) { proof[:run_attempt] = 2 },
      'PR number' => ->(proof) { proof[:pull_request][:number] = 8 },
      'head commit' => ->(proof) { proof[:pull_request][:head][:sha] = 'stale' },
      'head branch' => ->(proof) { proof[:pull_request][:head][:ref] = 'another' },
      'head repository' => ->(proof) { proof[:pull_request][:head][:repo][:id] = 43 },
      'base repository' => ->(proof) { proof[:pull_request][:base][:repo][:id] = 2 },
      'missing target' => ->(proof) { proof[:pull_request][:base][:ref] = '' },
      'multiple targets' => ->(proof) { proof[:pull_request] = [proof[:pull_request]] }
    }.each do |name, change|
      it "rejects provenance with a mismatched #{name}" do
        change.call(provenance)
        result = execute_workflow

        expect(result.fetch('failures')).not_to be_empty
        expect(result.fetch('calls')).to be_empty
      end
    end

    it 'keeps an explicit base-branch as a hard restriction' do
      fixture[:inputs]['base-branch'] = 'main'
      result = execute_workflow

      expect(result.fetch('failures')).not_to be_empty
      expect(result.fetch('calls')).to be_empty
    end

    it 'accepts an explicit base that matches the authenticated target' do
      fixture[:inputs]['base-branch'] = 'feature/lower'

      expect(execute_workflow.fetch('calls').last).to include('method' => 'createComment')
    end

    it 'rejects a run after the lower PR merges and GitHub retargets the upper PR' do
      pr[:base][:ref] = 'main'
      result = execute_workflow

      expect(result.fetch('failures')).not_to be_empty
      expect(result.fetch('calls').map { |call| call.fetch('method') }).to eq(['get'])
    end

    it 'accepts a fresh event-triggered run after retargeting' do
      pr[:base][:ref] = 'main'
      provenance[:pull_request][:base][:ref] = 'main'
      provenance[:run_id] = run[:id] = 124
      result = execute_workflow

      expect(result.fetch('failures')).to be_empty
      expect(result.fetch('calls').last).to include('method' => 'createComment')
    end

    it 'accepts matching proof from a new attempt of an unchanged event' do
      provenance[:run_attempt] = run[:run_attempt] = 2
      result = execute_workflow

      expect(result.fetch('failures')).to be_empty
      expect(result.fetch('calls').last).to include('method' => 'createComment')
    end

    it 'rejects a stale live head even with a valid original proof' do
      pr[:head][:sha] = 'new-commit'
      result = execute_workflow

      expect(result.fetch('failures')).not_to be_empty
      expect(result.fetch('calls').map { |call| call.fetch('method') }).to eq(['get'])
    end

    it 'fails closed for an inaccessible fork PR' do
      result = execute_workflow(apiError: true)

      expect(result.fetch('failures')).not_to be_empty
      expect(result.fetch('calls').map { |call| call.fetch('method') }).to eq(['get'])
    end
  end

  %w[push workflow_dispatch].each do |event|
    it "skips #{event} runs" do
      run[:event] = event
      result = execute_workflow

      expect(result.fetch('skipped')).to be true
      expect(result.fetch('calls')).to be_empty
    end
  end

  %w[cancelled skipped timed_out action_required].each do |conclusion|
    it "skips #{conclusion} runs" do
      run[:conclusion] = conclusion
      result = execute_workflow

      expect(result.fetch('skipped')).to be true
      expect(result.fetch('calls')).to be_empty
    end
  end

  it 'skips callers without a workflow_run event' do
    fixture[:context][:eventName] = 'workflow_dispatch'
    fixture[:context][:payload].delete(:workflow_run)
    result = execute_workflow

    expect(result.fetch('skipped')).to be true
    expect(result.fetch('calls')).to be_empty
  end
end
