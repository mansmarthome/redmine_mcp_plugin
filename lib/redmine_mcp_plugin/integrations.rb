# frozen_string_literal: true

module RedmineMcpPlugin
  # Detects optional host plugins and keeps their data out of the MCP surface
  # when they are not installed or not enabled. Detection is per call so a
  # plugin loaded after boot is picked up, and a missing constant never becomes
  # a tool, schema field, or payload key.
  module Integrations
    module_function

    # RedmineUP Checklists (and the same Checklist association redmine_agile
    # and the dashboard use). Absent when the constant or the association is
    # missing, including a partial load.
    def checklists?
      return false unless Object.const_defined?(:Checklist)
      return false unless defined?(Issue)

      Issue.reflect_on_association(:checklists).present?
    rescue StandardError
      false
    end

    # additional_tags issue tags. The plugin can be installed with issue tags
    # turned off; that is treated as no support.
    def issue_tags?
      return false unless defined?(AdditionalTags) && AdditionalTags.respond_to?(:setting?)
      return false unless AdditionalTags.setting?(:active_issue_tags)
      return false unless defined?(Issue) && Issue.method_defined?(:tag_list)

      true
    rescue StandardError
      false
    end

    # Checklist and tag journal details carry item text. Hide them from a caller
    # who may read the issue but not that integration, and ignore the keys
    # entirely when the plugin is not loaded.
    def hide_journal_detail?(issue, detail, user)
      return false unless detail.property == 'attr'

      case detail.prop_key
      when 'checklist'
        checklists? && !user.allowed_to?(:view_checklists, issue.project)
      when 'tag_list'
        issue_tags? && !user.allowed_to?(:view_issue_tags, issue.project)
      else
        false
      end
    end
  end
end
