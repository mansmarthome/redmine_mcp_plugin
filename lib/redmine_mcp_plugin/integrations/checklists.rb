# frozen_string_literal: true

module RedmineMcpPlugin
  module Integrations
    # Reads and writes RedmineUP checklist items through Issue nested attributes,
    # which is the path the plugin's safe_attributes gate and save callbacks use.
    module Checklists
      module_function

      ITEM_FIELDS = %w[id subject is_done is_section position _destroy].freeze

      def payload(issue)
        issue.checklists.map { |item| item_payload(item) }
      end

      def item_payload(item)
        {
          id: item.id,
          subject: item.subject,
          is_done: !!item.is_done,
          is_section: !!item.is_section,
          position: item.position,
          created_at: item.created_at&.iso8601,
          updated_at: item.updated_at&.iso8601
        }
      end

      def summary(issue)
        items = issue.checklists.reject(&:is_section)
        { total: items.size, done: items.count(&:is_done) }
      end

      # items is an array of string-keyed hashes in the REST checklists_attributes
      # shape. subject is required on every item, including updates and removals,
      # because the plugin drops an item whose subject is blank.
      def apply!(issue, items, user)
        before = issue.persisted? ? issue.checklists.map(&:dup) : []
        assign!(issue, items, user)
        unless issue.save
          raise RedmineMcpPlugin::ToolError, "Could not update checklists: #{issue.errors.full_messages.join('; ')}"
        end

        recalc!(issue)
        record_journal(issue, before, user)
        issue.reload
      end

      def assign!(issue, items, user)
        normalized = Array(items).map { |item| item.to_h.stringify_keys.slice(*ITEM_FIELDS) }
        raise RedmineMcpPlugin::ToolError, 'checklists must not be empty' if normalized.empty?

        known = issue.persisted? ? issue.checklists.map(&:id) : []
        normalized.each do |item|
          raise RedmineMcpPlugin::ToolError, 'subject is required for every checklist item' if item['subject'].blank?
          if item['_destroy'] == true && item['id'].blank?
            raise RedmineMcpPlugin::ToolError, 'a checklist id is required to remove an item'
          end
          next if item['id'].blank?
          next if known.include?(item['id'].to_i)

          raise RedmineMcpPlugin::ToolError, "No visible checklist item with id #{item['id'].inspect}"
        end

        issue.send(:safe_attributes=, { 'checklists_attributes' => attributes_hash(normalized, issue) }, user)
      end

      def mark_done!(item, is_done, user)
        before = item.issue.checklists.map(&:dup)
        item.is_done = is_done
        unless item.save
          raise RedmineMcpPlugin::ToolError, "Could not update checklist: #{item.errors.full_messages.join('; ')}"
        end

        recalc!(item.issue)
        record_journal(item.issue, before, user)
        item.reload
      end

      def attributes_hash(items, issue)
        next_position = (issue.checklists.map(&:position).compact.max || 0) + 1
        items.each_with_index.to_h do |item, index|
          attrs = { 'subject' => item['subject'].to_s }
          attrs['id'] = item['id'].to_i if item['id'].present?
          attrs['is_done'] = item['is_done'] if item.key?('is_done')
          attrs['is_section'] = item['is_section'] if item.key?('is_section')
          if item['position'].present?
            attrs['position'] = item['position']
          elsif item['id'].blank?
            attrs['position'] = next_position + index
          end
          attrs['_destroy'] = '1' if item['_destroy'] == true
          [index.to_s, attrs]
        end
      end

      def recalc!(issue)
        return unless defined?(Checklist) && Checklist.respond_to?(:recalc_issue_done_ratio)
        return unless defined?(RedmineChecklists) && RedmineChecklists.respond_to?(:issue_done_ratio?)
        return unless RedmineChecklists.issue_done_ratio?
        return unless Setting.issue_done_ratio == 'issue_field'

        Checklist.recalc_issue_done_ratio(issue.id)
      end

      def record_journal(issue, before, user)
        return unless log_changes?
        return unless defined?(JournalChecklistHistory)

        after = issue.checklists.reload.to_a
        return if snapshot(before) == snapshot(after)
        return if recent_checklist_journal?(issue, user)

        issue.init_journal(user)
        issue.current_journal.details << JournalChecklistHistory.new(before, after).journal_details
        issue.save!
      end

      def log_changes?
        return false unless defined?(RedmineChecklists) && RedmineChecklists.respond_to?(:settings)

        value = RedmineChecklists.settings['save_log']
        value == true || %w[1 true yes on].include?(value.to_s.strip.downcase) || value.to_i.positive?
      rescue StandardError
        false
      end

      def recent_checklist_journal?(issue, user)
        issue.journals.joins(:details)
             .where(user_id: user.id, journal_details: { prop_key: 'checklist' })
             .where('journals.created_on >= ?', 2.seconds.ago)
             .exists?
      end

      def snapshot(items)
        items.map { |item| [item.id, item.subject.to_s, !!item.is_done, !!item.is_section, item.position] }
      end
    end
  end
end
