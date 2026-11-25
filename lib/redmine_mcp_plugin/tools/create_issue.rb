# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class CreateIssue < Base
      tool_name 'create_issue'
      title 'Create issue'
      description 'Create a new issue in a project.'

      def self.description_value
        notes = []
        notes << 'Accepts checklists when checklists are installed; that requires edit_checklists.' if Integrations.checklists?
        if Integrations.issue_tags?
          notes << 'Accepts tags when issue tags are enabled; that requires edit_issue_tags, and create_issue_tags for a new name.'
        end
        notes.empty? ? super : "#{super} #{notes.join(' ')}"
      end

      def self.optional_input_properties
        properties = {}
        if Integrations.checklists?
          properties['checklists'] = {
            'type' => 'array',
            'description' => 'Checklist items to add. Requires edit_checklists. subject is required on every item.',
            'items' => {
              'type' => 'object',
              'properties' => {
                'subject' => { 'type' => 'string' },
                'is_done' => { 'type' => 'boolean' },
                'is_section' => { 'type' => 'boolean' },
                'position' => { 'type' => 'integer', 'minimum' => 1 }
              },
              'required' => %w[subject],
              'additionalProperties' => false
            }
          }
        end
        if Integrations.issue_tags?
          properties['tags'] = {
            'type' => 'array',
            'items' => { 'type' => 'string' },
            'description' => 'Tags to set. Each entry is one tag. Requires edit_issue_tags; a new name also requires create_issue_tags.'
          }
        end
        properties
      end

      def self.required_permissions(arguments = {})
        permissions = super
        if Integrations.checklists? && Array(arguments['checklists']).any?
          permissions << :edit_checklists
        end
        if Integrations.issue_tags? && arguments.key?('tags')
          permissions.concat(
            Integrations::IssueTags.permissions_for(Integrations::IssueTags.normalize(arguments['tags']), 'replace')
          )
        end
        permissions.uniq
      end

      permission :add_issues
      write true
      input_schema(
        'type' => 'object',
        'properties' => {
          'project' => { 'type' => %w[string integer],
                         'description' => 'Project identifier or numeric id.' },
          'subject' => { 'type' => 'string', 'description' => 'Issue subject.' },
          'description' => { 'type' => 'string' },
          'tracker' => { 'type' => 'string', 'description' => 'Tracker name. Defaults to the project default.' },
          'priority' => { 'type' => 'string', 'description' => 'Priority name. Defaults to the Redmine default.' },
          'assigned_to' => { 'type' => 'string', 'description' => 'Login of the user to assign to.' }
        },
        'required' => %w[project subject],
        'additionalProperties' => false
      )

      private

      def perform(arguments)
        project = fetch_project(arguments['project'])
        authorize!(:add_issues, project)

        issue = Issue.new(project: project, author: user)
        attributes = { 'subject' => arguments['subject'].to_s,
                       'description' => arguments['description'].to_s }

        if (tracker_name = arguments['tracker'].presence)
          tracker = project.trackers.find_by(name: tracker_name.to_s)
          raise ToolError, "Project #{project.identifier} has no tracker named #{tracker_name.inspect}" if tracker.nil?

          attributes['tracker_id'] = tracker.id
        end

        if (priority_name = arguments['priority'].presence)
          priority = IssuePriority.active.find_by(name: priority_name.to_s)
          raise ToolError, "No active priority named #{priority_name.inspect}" if priority.nil?

          attributes['priority_id'] = priority.id
        end

        if (login = arguments['assigned_to'].presence)
          assignee = project.assignable_users.find_by(login: login.to_s)
          raise ToolError, "#{login.inspect} is not an assignable user on #{project.identifier}" if assignee.nil?

          attributes['assigned_to_id'] = assignee.id
        end

        issue.safe_attributes = attributes
        assign_checklists(issue, project, arguments)
        assign_tags(issue, project, arguments)
        raise ToolError, "Could not create issue: #{issue.errors.full_messages.join('; ')}" unless issue.save

        if Integrations.checklists? && Array(arguments['checklists']).any?
          Integrations::Checklists.recalc!(issue)
          Integrations::Checklists.record_journal(issue, [], user)
        end
        issue.reload

        payload = { id: issue.id, subject: issue.subject, project_identifier: project.identifier,
                    status: issue.status&.name, tracker: issue.tracker&.name, created_on: iso(issue.created_on) }
        if Integrations.checklists? && arguments.key?('checklists') && user.allowed_to?(:view_checklists, project)
          payload[:checklists] = Integrations::Checklists.payload(issue)
        end
        if Integrations.issue_tags? && arguments.key?('tags') && user.allowed_to?(:view_issue_tags, project)
          payload[:tags] = Integrations::IssueTags.names(issue)
        end
        payload
      end

      def assign_checklists(issue, project, arguments)
        return unless Integrations.checklists? && Array(arguments['checklists']).any?

        authorize!(:edit_checklists, project)
        Integrations::Checklists.assign!(issue, arguments['checklists'], user)
      end

      def assign_tags(issue, project, arguments)
        return unless Integrations.issue_tags? && arguments.key?('tags')

        authorize!(:edit_issue_tags, project)
        names = Integrations::IssueTags.normalize(arguments['tags'])
        unless issue.tags_allowed_for?(user, names)
          raise ToolError, 'You do not have permission to do that'
        end

        issue.tag_list = AdditionalTags::TagList.new(*names)
      end
    end
  end
end
