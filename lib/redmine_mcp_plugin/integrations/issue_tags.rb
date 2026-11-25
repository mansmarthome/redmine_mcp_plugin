# frozen_string_literal: true

module RedmineMcpPlugin
  module Integrations
    # Reads and writes additional_tags issue tags. New names need
    # create_issue_tags; assigning only existing visible tags needs
    # edit_issue_tags. Removing tags creates nothing.
    module IssueTags
      module_function

      def names(issue)
        issue.tag_list.to_a
      end

      def normalize(value)
        Array(value).map { |name| name.to_s.strip }.reject(&:blank?)
      end

      # Permissions the HTTP gate should challenge for. create_issue_tags is
      # added only when a name is not already visible to the user, matching the
      # plugin's edit-versus-create split.
      def permissions_for(names, mode, user = User.current)
        permissions = [:edit_issue_tags]
        return permissions if mode == 'remove' || names.empty?
        return permissions if known_tags?(names, user)

        permissions << :create_issue_tags
      end

      # additional_tags defines Issue#tags_allowed_for? only in newer releases.
      # Older hosts still expose tag_list, so the same rule is applied here when
      # the method is absent: editing allows existing tags, creating allows new ones.
      def allowed?(issue, user, tag_names)
        return issue.tags_allowed_for?(user, tag_names) if issue.respond_to?(:tags_allowed_for?)

        user.allowed_to?(:edit_issue_tags, issue.project) &&
          (tag_names.empty? || user.allowed_to?(:create_issue_tags, issue.project) || known_tags?(tag_names, user))
      end

      def apply!(issue, names, mode, user)
        current = issue.tag_list.dup
        updated =
          case mode
          when 'append' then current.add(names)
          when 'remove' then current.remove(names)
          when 'replace' then AdditionalTags::TagList.new(*names)
          else
            raise RedmineMcpPlugin::ToolError, 'mode must be replace, append, or remove'
          end

        checked = mode == 'append' ? names : updated.to_a
        unless mode == 'remove' || allowed?(issue, user, checked)
          raise RedmineMcpPlugin::ToolError, 'You do not have permission to do that'
        end

        before = current.to_s
        issue.init_journal(user)
        issue.tag_list = updated
        journal!(issue, before, issue.tag_list.to_s)
        unless issue.save
          raise RedmineMcpPlugin::ToolError, "Could not update tags: #{issue.errors.full_messages.join('; ')}"
        end

        issue.reload
        names(issue)
      end

      def known_tags?(names, user)
        if Issue.respond_to?(:allowed_tags?)
          method = Issue.method(:allowed_tags?)
          # Older additional_tags takes only the names; newer releases add user:.
          return method.parameters.any? { |_type, name| name == :user } ? method.call(names, user: user) : method.call(names)
        end
        return false unless Issue.respond_to?(:available_tags)

        known = Issue.available_tags(user: user).map(&:name)
        names.all? { |name| known.include?(name) }
      end

      def journal!(issue, before, after)
        return if before == after

        if issue.respond_to?(:tags_to_journal)
          issue.tags_to_journal(before, after)
        else
          issue.current_journal.details << JournalDetail.new(
            property: 'attr', prop_key: 'tag_list', old_value: before, value: after
          )
        end
      end
    end
  end
end
