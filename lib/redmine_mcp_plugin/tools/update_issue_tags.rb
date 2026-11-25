# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class UpdateIssueTags < Base
      include VisibleIssue

      tool_name 'update_issue_tags'
      title 'Update issue tags'
      description 'Replace, append, or remove tags on an issue. replace is the default and an empty list clears tags. ' \
                  'Requires edit_issue_tags. A tag name that does not already exist also requires create_issue_tags.'
      permission :edit_issue_tags
      write true
      destructive true
      input_schema(
        'type' => 'object',
        'properties' => {
          'id' => { 'type' => 'integer', 'description' => 'Issue id.' },
          'tags' => { 'type' => 'array', 'items' => { 'type' => 'string' },
                      'description' => 'Tag names. Each entry is one tag.' },
          'mode' => { 'type' => 'string', 'enum' => %w[replace append remove],
                      'description' => 'How tags are applied. Defaults to replace.' }
        },
        'required' => %w[id tags],
        'additionalProperties' => false
      )

      def self.required_permissions(arguments = {})
        permissions = super
        return permissions unless Integrations.issue_tags?

        mode = arguments['mode'].presence || 'replace'
        names = Integrations::IssueTags.normalize(arguments['tags'])
        (permissions + Integrations::IssueTags.permissions_for(names, mode)).uniq
      end

      private

      def perform(arguments)
        raise ToolError, UNAVAILABLE unless Integrations.issue_tags?

        issue = visible_issue!(arguments['id'])
        authorize!(:edit_issue_tags, issue.project)
        mode = arguments['mode'].presence || 'replace'
        names = Integrations::IssueTags.normalize(arguments['tags'])
        raise ToolError, 'tags must not be empty' if names.empty? && mode != 'replace'

        tags = Integrations::IssueTags.apply!(issue, names, mode, user)
        { issue_id: issue.id, tags: tags }
      end
    end
  end
end