# frozen_string_literal: true

require 'json'
require 'danger-pr-comment/renderer'

module DangerPrComment
  class Reporter
    def initialize(status_report)
      @status_report = status_report
    end

    def export_json(report_path, event_path, summary_path: nil)
      return unless report_path && event_path && File.exist?(event_path)

      event = JSON.parse(File.read(event_path))
      pr_number = event.dig('pull_request', 'number')
      return unless pr_number

      report = build_report(pr_number)
      File.write(report_path, JSON.pretty_generate(report))
      export_summary(summary_path, report[:rendered_markdown])
    end

    private

    def build_report(pr_number)
      report = {
        pr_number: pr_number,
        errors: to_messages(@status_report[:errors]),
        warnings: to_messages(@status_report[:warnings]),
        messages: to_messages(@status_report[:messages]),
        markdowns: to_messages(@status_report[:markdowns])
      }
      report.merge(rendered_markdown: Renderer.new(report).render)
    end

    def export_summary(path, markdown)
      return unless path

      File.open(path, 'a') { |file| file.write("## Danger Report\n\n#{markdown}\n") }
    end

    def to_messages(items)
      Array(items).map do |item|
        item.respond_to?(:message) ? item.message : item.to_s
      end
    end
  end
end
