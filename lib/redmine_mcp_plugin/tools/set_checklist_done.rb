# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class SetChecklistDone < Base
      tool_name 'set_checklist_done'
      title 'Set checklist item done'
      description 'Mark one checklist item done or not done. Does not edit its text. Requires done_checklists.'
      permission :done_checklists
      write true
      input_schema(
        'type' => 'object',
        'properties' => {
          'id' => { 'type' => 'integer', 'description' => 'Checklist item id.' },
          'is_done' => { 'type' => 'boolean', 'description' => 'Whether the item is done.' }
        },
        'required' => %w[id is_done],
        'additionalProperties' => false
      )

      private

      def perform(arguments)
        raise ToolError, UNAVAILABLE unless Integrations.checklists?

        item = Checklist.joins(:issue).merge(Issue.visible(user)).find_by(id: arguments['id'].to_i)
        visible = item&.issue&.visible?(user) && user.allowed_to?(:view_checklists, item.issue.project)
        raise ToolError, "No visible checklist item with id #{arguments['id'].inspect}" unless visible

        authorize!(:done_checklists, item.issue.project)
        Integrations::Checklists.mark_done!(item, arguments['is_done'] == true, user)
        { issue_id: item.issue_id, checklist: Integrations::Checklists.item_payload(item) }
      end
    end
  end
end
