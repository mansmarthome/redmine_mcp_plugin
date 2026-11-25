# frozen_string_literal: true

module RedmineMcpPlugin
  # Explicitly registers exposed tools so a stray file cannot become an
  # authenticated endpoint without a visible registry change.
  module Registry
    class << self
      def all
        [
          Tools::WhoAmI,
          Tools::ListProjects,
          Tools::GetProject,
          Tools::GetIssue,
          Tools::SearchIssues,
          Tools::ListWikiPages,
          Tools::GetWikiPage,
          Tools::ListEnumerations,
          Tools::ListStatuses,
          Tools::ListVersions,
          Tools::ListUsers,
          Tools::GetGroup,
          Tools::CreateIssue,
          Tools::AddIssueNote,
          Tools::CreateVersion,
          Tools::CreateWikiPage,
          *optional
        ]
      end

      private

      # Host plugins are not requirements. Their tools stay out of tools/list
      # and tools/call unless the plugin is loaded and its feature is enabled.
      def optional
        tools = []
        if Integrations.checklists?
          tools << Tools::UpdateIssueChecklists
          tools << Tools::SetChecklistDone
        end
        if Integrations.issue_tags?
          tools << Tools::ListIssueTags
          tools << Tools::UpdateIssueTags
        end
        tools
      end
    end
  end
end
