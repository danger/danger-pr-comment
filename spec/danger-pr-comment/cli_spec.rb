# frozen_string_literal: true

require 'spec_helper'
require 'danger-pr-comment/cli'
require 'stringio'
require 'tempfile'

RSpec.describe DangerPrComment::CLI do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:file) { Tempfile.new(['danger-report', '.json']) }

  before { File.write(file.path, JSON.generate(errors: ['Fix the build'])) }
  after { file.close! }

  def run_cli(*args)
    described_class.run(args, out: out, err: err)
  end

  it 'renders findings without treating them as command failures' do
    expect(run_cli('render', file.path)).to eq(0)
    expect(out.string).to eq("### Errors\n- Fix the build\n")
    expect(err.string).to be_empty
  end

  it 'prints help without reading a report' do
    expect(run_cli('--help')).to eq(0)
    expect(out.string).to include('render REPORT.json')
    expect(err.string).to be_empty
  end

  it 'reports invalid usage' do
    expect(run_cli).to eq(1)
    expect(out.string).to be_empty
    expect(err.string).to include('Usage:')
  end

  it 'reports malformed JSON without emitting partial Markdown' do
    File.write(file.path, '{')

    expect(run_cli('render', file.path)).to eq(1)
    expect(out.string).to be_empty
    expect(err.string).not_to be_empty
  end

  it 'reports a JSON root that is not an object' do
    File.write(file.path, '[]')

    expect(run_cli('render', file.path)).to eq(1)
    expect(out.string).to be_empty
    expect(err.string).to include('Danger report must be a JSON object')
  end

  it 'reports missing files on stderr' do
    expect(run_cli('render', "#{file.path}.missing")).to eq(1)
    expect(out.string).to be_empty
    expect(err.string).to include("#{file.path}.missing")
  end
end
