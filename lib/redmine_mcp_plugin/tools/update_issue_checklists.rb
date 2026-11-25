# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class UpdateIssueChecklists < Base
      include VisibleIssue

      tool_name 'update_issue_checklists'
      title 'Update issue checklists'
      description 'Add, update, reorder, complete, or remove checklist items on an issue. ' \
                  'Items without id are added, items with id are updated, and _destroy removes one. ' \
                  'subject is required for every item, including updates and removals. ' \
                  'Requires edit_checklists.'
      permission :edit_checklists
      write true
      destructive true
      input_schema(
        'type' => 'object',
        'properties' => {
          'id' => { 'type' => 'integer', 'description' => 'Issue id.' },
          'checklists' => {
            'type' => 'array',
            'description' => 'Checklist items in the REST API shape.',
            'items' => {
              'type' => 'object',
              'properties' => {
                'id' => { 'type' => 'integer', 'description' => 'Existing item id. Omit to add.' },
                'subject' => { 'type' => 'string', 'description' => 'Item text. Required, including when updating or removing.' },
                'is_done' => { 'type' => 'boolean', 'description' => 'Whether the item is done.' },
                'is_section' => { 'type' => 'boolean', 'description' => 'Whether the item is a section header.' },
                'position' => { 'type' => 'integer', 'minimum' => 1, 'description' => '1-based position. Defaults to the end.' },
                '_destroy' => { 'type' => 'boolean', 'description' => 'Remove the item with this id.' }
              },
              'required' => %w[subject],
              'additionalProperties' => false
            }
          }
        },
        'required' => %w[id checklists],
        'additionalProperties' => false
      )

      private

      def perform(arguments)
        raise ToolError, UNAVAILABLE unless Integrations.checklists?

        issue = visible_issue!(arguments['id'])
        authorize!(:edit_checklists, issue.project)
        Integrations::Checklists.apply!(issue, arguments['checklists'], user)
        { issue_id: issue.id, checklists: Integrations::Checklists.payload(issue) }
      end
    end
  end
end
