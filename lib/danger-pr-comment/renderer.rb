# frozen_string_literal: true

module DangerPrComment
  class Renderer
    LIST_SECTIONS = { 'errors' => 'Errors', 'warnings' => 'Warnings', 'messages' => 'Messages' }.freeze

    def initialize(report)
      raise ArgumentError, 'Danger report must be a JSON object' unless report.is_a?(Hash)

      @report = report.transform_keys(&:to_s)
    end

    def render
      sections = list_sections
      markdowns = items('markdowns')
      sections << "### Markdowns\n#{markdowns.join("\n\n")}" unless markdowns.empty?
      "#{sections.empty? ? 'No issues found.' : sections.join("\n\n")}\n"
    end

    private

    def list_sections
      LIST_SECTIONS.filter_map do |key, title|
        messages = items(key)
        next if messages.empty?

        "### #{title}\n#{messages.map { |message| "- #{message}" }.join("\n")}"
      end
    end

    def items(key)
      value = @report[key]
      value.is_a?(Array) ? value : []
    end
  end
end
