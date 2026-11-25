# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class ListIssueTags < Base
      tool_name 'list_issue_tags'
      title 'List issue tags'
      description 'List issue tags visible to the caller, optionally limited to one project. Requires view_issue_tags.'
      permission :view_issue_tags
      input_schema(
        'type' => 'object',
        'properties' => {
          'project' => { 'type' => %w[string integer],
                         'description' => 'Restrict to one project (identifier or numeric id).' },
          'offset' => { 'type' => 'integer', 'minimum' => 0,
                        'description' => 'Tags to skip. Defaults to 0.' },
          'limit' => { 'type' => 'integer', 'minimum' => 1,
                       'description' => 'Maximum tags to return, clamped by the server cap.' }
        },
        'additionalProperties' => false
      )

      private

      def perform(arguments)
        raise ToolError, UNAVAILABLE unless Integrations.issue_tags?

        project = arguments['project'].presence && fetch_project(arguments['project'])
        authorize!(:view_issue_tags, project) if project

        scope = Issue.available_tags(project: project, user: user, permission: :view_issue_tags)
        total = tag_count(scope)
        offset = offset_for(arguments)
        limit = limit_for(arguments)
        rows = scope.offset(offset).limit(limit).map { |tag| { id: tag.id, name: tag.name } }
        paged(total: total, offset: offset, key: :tags, rows: rows)
      end

      def tag_count(scope)
        count = scope.unscope(:select, :order).count
        count.is_a?(Hash) ? count.size : count
      end
    end
  end
end
