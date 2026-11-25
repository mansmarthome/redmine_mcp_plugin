# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class SearchIssues < Base
      tool_name 'search_issues'
      title 'Search issues'
      description 'Search issues visible to the authenticated user. All filters are optional ' \
                  'and are combined with AND. Returns newest-updated first.'

      def self.description_value
        note = if Integrations.issue_tags?
                 ' When issue tags are enabled, tags filters the result and each row includes tags the caller may view.'
               else
                 ''
               end
        checklist = if Integrations.checklists?
                      ' Each row includes a checklist done/total summary when the caller may view checklists.'
                    else
                      ''
                    end
        "#{super}#{note}#{checklist}"
      end

      def self.optional_input_properties
        return {} unless Integrations.issue_tags?

        {
          'tags' => {
            'type' => 'array',
            'items' => { 'type' => 'string' },
            'description' => 'Only issues carrying these tags. Requires view_issue_tags.'
          },
          'tags_match' => {
            'type' => 'string',
            'enum' => %w[all any],
            'description' => 'Whether every tag is required (all, the default) or any one tag is enough.'
          }
        }
      end

      def self.required_permissions(arguments = {})
        permissions = super
        if Integrations.issue_tags? && Array(arguments['tags']).any?
          permissions << :view_issue_tags
        end
        permissions
      end
      permission :view_issues
      input_schema(
        'type' => 'object',
        'properties' => {
          'project' => { 'type' => %w[string integer],
                         'description' => 'Restrict to one project (identifier or numeric id).' },
          'query' => { 'type' => 'string', 'description' => 'Case-insensitive substring matched against subject and description.' },
          'status' => { 'type' => 'string', 'enum' => %w[open closed all],
                        'description' => 'Issue status filter. Defaults to open.' },
          'tracker' => { 'type' => 'string', 'description' => 'Tracker name, e.g. Bug.' },
          'assigned_to_me' => { 'type' => 'boolean', 'description' => 'Only issues assigned to the authenticated user.' },
          'fixed_version_id' => { 'type' => 'integer', 'description' => 'Only issues targeting this version id.' },
          'author_id' => { 'type' => 'integer', 'description' => 'Only issues created by this user id.' },
          'category_id' => { 'type' => 'integer', 'description' => 'Only issues in this category id.' },
          'updated_since' => { 'type' => 'string', 'format' => 'date',
                               'description' => 'Only issues updated on or after this ISO-8601 date.' },
          'created_from' => { 'type' => 'string', 'format' => 'date',
                              'description' => 'Only issues created on or after this ISO-8601 date.' },
          'created_to' => { 'type' => 'string', 'format' => 'date',
                            'description' => 'Only issues created on or before this ISO-8601 date.' },
          'sort' => { 'type' => 'string',
                      'enum' => %w[updated_on updated_on:desc created_on created_on:desc id id:desc],
                      'description' => 'Result order. Defaults to updated_on:desc.' },
          'offset' => { 'type' => 'integer', 'minimum' => 0,
                        'description' => 'Rows to skip, for paging past the server cap. Defaults to 0.' },
          'limit' => { 'type' => 'integer', 'minimum' => 1, 'description' => 'Maximum issues to return.' }
        },
        'additionalProperties' => false
      )

      private

      def perform(arguments)
        scope = Issue.visible(user)
                     .includes(:project, :tracker, :status, :priority, :author, :assigned_to, :category, :fixed_version)
        scope = scope.preload(:checklists) if Integrations.checklists?
        scope = scope.preload(:tags) if Integrations.issue_tags?

        if (identifier = arguments['project'].presence)
          project = fetch_project(identifier)
          # .visible filters by role but not by a narrowed OAuth scope.
          authorize!(:view_issues, project)
          authorize!(:view_issue_tags, project) if Integrations.issue_tags? && Array(arguments['tags']).any?
          scope = scope.where(project_id: project.id)
        end

        scope =
          case arguments['status'].presence&.to_s
          when 'closed' then scope.joins(:status).where(issue_statuses: { is_closed: true })
          when 'all'    then scope
          else scope.open
          end

        if (needle = arguments['query'].presence)
          pattern = "%#{ActiveRecord::Base.sanitize_sql_like(needle.to_s)}%"
          scope = scope.where('LOWER(issues.subject) LIKE LOWER(:p) OR LOWER(issues.description) LIKE LOWER(:p)', p: pattern)
        end

        if (tracker_name = arguments['tracker'].presence)
          tracker = Tracker.find_by(name: tracker_name.to_s)
          raise ToolError, "No tracker named #{tracker_name.inspect}" if tracker.nil?

          scope = scope.where(tracker_id: tracker.id)
        end

        scope = scope.where(assigned_to_id: user.id) if arguments['assigned_to_me']
        scope = scope.where(fixed_version_id: arguments['fixed_version_id'].to_i) if arguments['fixed_version_id'].present?
        scope = scope.where(author_id: arguments['author_id'].to_i) if arguments['author_id'].present?
        scope = scope.where(category_id: arguments['category_id'].to_i) if arguments['category_id'].present?
        scope = tagged(scope, arguments) if Integrations.issue_tags? && Array(arguments['tags']).any?

        if (since = arguments['updated_since'].presence)
          scope = scope.where('issues.updated_on >= ?', parse_date(since, 'updated_since').beginning_of_day)
        end
        if (from = arguments['created_from'].presence)
          scope = scope.where('issues.created_on >= ?', parse_date(from, 'created_from').beginning_of_day)
        end
        if (to = arguments['created_to'].presence)
          scope = scope.where('issues.created_on <= ?', parse_date(to, 'created_to').end_of_day)
        end

        limit  = limit_for(arguments)
        offset = offset_for(arguments)
        rows   = scope.reorder(order_for(arguments['sort'])).offset(offset).limit(limit)
                      .map { |issue| summarise(issue) }
        paged(total: scope.count, offset: offset, key: :issues, rows: rows)
      end

      def parse_date(value, field)
        Date.iso8601(value.to_s)
      rescue ArgumentError
        raise ToolError, "#{field} must be an ISO-8601 date, got #{value.inspect}"
      end

      def order_for(sort)
        case sort.presence&.to_s
        when 'updated_on'      then { updated_on: :asc }
        when 'created_on'      then { created_on: :asc }
        when 'created_on:desc' then { created_on: :desc }
        when 'id'              then { id: :asc }
        when 'id:desc'         then { id: :desc }
        else { updated_on: :desc }
        end
      end

      def summarise(issue)
        row = {
          id: issue.id,
          subject: issue.subject,
          project: issue.project&.name,
          project_identifier: issue.project&.identifier,
          tracker: issue.tracker&.name,
          status: issue.status&.name,
          priority: issue.priority&.name,
          author: issue.author&.name,
          assigned_to: issue.assigned_to&.name,
          category: issue.category&.name,
          fixed_version: issue.fixed_version&.name,
          done_ratio: issue.done_ratio,
          created_on: iso(issue.created_on),
          updated_on: iso(issue.updated_on)
        }
        if Integrations.checklists? && user.allowed_to?(:view_checklists, issue.project)
          row[:checklists] = Integrations::Checklists.summary(issue)
        end
        if Integrations.issue_tags? && user.allowed_to?(:view_issue_tags, issue.project)
          row[:tags] = Integrations::IssueTags.names(issue)
        end
        row
      end

      def tagged(scope, arguments)
        names = Integrations::IssueTags.normalize(arguments['tags'])
        return scope if names.empty?

        any = arguments['tags_match'].to_s == 'any'
        scope.where(project_id: Project.allowed_to(user, :view_issue_tags).select(:id))
             .tagged_with(names, any: any)
      end
    end
  end
end
