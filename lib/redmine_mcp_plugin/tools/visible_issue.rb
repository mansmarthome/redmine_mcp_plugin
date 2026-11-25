# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    # Issue.visible honors roles but not a narrowed OAuth token. Issue#visible?
    # goes through allowed_to?, so a token without view_issues cannot write an
    # issue it could not read. view_issues stays out of required_permissions
    # because a write-tier challenge must not carry a read scope.
    module VisibleIssue
      private

      def visible_issue!(raw_id)
        issue = Issue.visible(user).find_by(id: raw_id.to_i)
        raise ToolError, "No visible issue with id #{raw_id.inspect}" unless issue&.visible?(user)

        issue
      end
    end
  end
end
