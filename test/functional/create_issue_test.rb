# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# Parent assignment on create_issue. Visibility, manage_subtasks, and the
# project parent rules are the security boundary; a missing parent and an
# invisible one must stay indistinguishable.
class RedmineMcpPluginCreateIssueTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :issues, :issue_statuses, :trackers, :enumerations, :enabled_modules

  def setup
    Setting.plugin_redmine_mcp_plugin = RedmineMcpPlugin::Settings::DEFAULTS.merge('read_only' => '1')
    Setting.clear_cache
  end

  def teardown
    Setting.clear_cache
  end

  def test_parent_id_is_optional_and_demands_manage_subtasks_only_when_present
    tool = RedmineMcpPlugin::Tools::CreateIssue

    assert_not_includes tool.required_permissions('project' => 'ecookbook', 'subject' => 'x'), :manage_subtasks
    assert_includes tool.required_permissions('parent_id' => 1), :manage_subtasks
  end

  def test_create_issue_assigns_a_visible_parent
    with_read_only_off do
      result = call_as(User.find(1), 'create_issue',
                       'project' => 'ecookbook', 'subject' => 'Child task', 'parent_id' => 1)[:result]

      assert_not result[:isError], result[:content]&.first&.dig(:text)
      assert_equal 1, result[:structuredContent][:parent_id]
      assert_equal 1, Issue.find(result[:structuredContent][:id]).parent_id
    end
  end

  def test_create_issue_without_a_parent_leaves_parent_id_nil
    with_read_only_off do
      result = call_as(User.find(1), 'create_issue',
                       'project' => 'ecookbook', 'subject' => 'Root task')[:result]

      assert_not result[:isError], result[:content]&.first&.dig(:text)
      assert_nil result[:structuredContent][:parent_id]
    end
  end

  def test_missing_and_invisible_parents_share_one_error
    user = User.find(3)
    Role.find(2).add_permission!(:add_issues, :manage_subtasks)
    parent = Issue.find(1)
    parent.update_columns(is_private: true, author_id: 1, assigned_to_id: nil)
    assert_not parent.visible?(user)

    with_read_only_off do
      missing = call_as(user, 'create_issue',
                        'project' => 'ecookbook', 'subject' => 'Missing parent', 'parent_id' => 999_999)[:result]
      hidden = call_as(user, 'create_issue',
                       'project' => 'ecookbook', 'subject' => 'Hidden parent', 'parent_id' => parent.id)[:result]

      assert missing[:isError]
      assert hidden[:isError]
      assert_equal "No visible issue with id 999999", missing[:content].first[:text]
      assert_equal "No visible issue with id #{parent.id}", hidden[:content].first[:text]
      assert_nil Issue.find_by(subject: 'Hidden parent')
    end
  end

  def test_create_issue_parent_requires_manage_subtasks_on_the_project
    user = User.find(3)
    project = Project.find_by!(identifier: 'ecookbook')
    Role.find(2).add_permission!(:add_issues)
    Role.find(2).remove_permission!(:manage_subtasks)
    grant_manage_subtasks_elsewhere(user)

    assert user.allowed_to?(:add_issues, project)
    assert user.allowed_to?(:manage_subtasks, nil, global: true)
    assert_not user.allowed_to?(:manage_subtasks, project)

    with_read_only_off do
      result = call_as(user, 'create_issue',
                       'project' => 'ecookbook', 'subject' => 'Denied parent', 'parent_id' => 1)[:result]

      assert result[:isError]
      assert_match(/permission/i, result[:content].first[:text])
      assert_nil Issue.find_by(subject: 'Denied parent')
    end
  end

  def test_oauth_token_without_view_issues_cannot_assign_a_parent
    user = User.find(2)
    user.roles.each { |role| role.add_permission!(:add_issues, :manage_subtasks) }
    user.oauth_scope = %i[add_issues manage_subtasks]

    with_read_only_off do
      result = call_as(user, 'create_issue',
                       'project' => 'ecookbook', 'subject' => 'Scoped child', 'parent_id' => 1)[:result]

      assert result[:isError]
      assert_match(/No visible issue with id 1/, result[:content].first[:text])
      assert_nil Issue.find_by(subject: 'Scoped child')
    end
  ensure
    user.oauth_scope = nil if user
  end

  def test_create_issue_refuses_a_parent_outside_the_allowed_projects
    parent = Issue.visible(User.find(1)).where.not(project_id: Project.find_by!(identifier: 'ecookbook').id).first
    assert parent, 'fixture must include a visible issue outside ecookbook'

    with_settings(cross_project_subtasks: '') do
      with_read_only_off do
        result = call_as(User.find(1), 'create_issue',
                         'project' => 'ecookbook', 'subject' => 'Cross project',
                         'parent_id' => parent.id)[:result]

        assert result[:isError]
        assert_match(/not a valid parent/, result[:content].first[:text])
        assert_nil Issue.find_by(subject: 'Cross project')
      end
    end
  end

  def test_create_issue_accepts_a_cross_project_parent_when_the_setting_allows_it
    parent = Issue.visible(User.find(1)).where.not(project_id: Project.find_by!(identifier: 'ecookbook').id).
             detect { |issue| !issue.closed? }
    assert parent, 'fixture must include an open issue outside ecookbook'

    with_settings(cross_project_subtasks: 'system') do
      with_read_only_off do
        result = call_as(User.find(1), 'create_issue',
                         'project' => 'ecookbook', 'subject' => 'System parent',
                         'parent_id' => parent.id)[:result]

        assert_not result[:isError], result[:content]&.first&.dig(:text)
        assert_equal parent.id, result[:structuredContent][:parent_id]
      end
    end
  end

  def test_create_issue_refuses_a_closed_parent
    closed = IssueStatus.where(is_closed: true).first
    assert closed
    Issue.find(1).update_columns(status_id: closed.id)

    with_read_only_off do
      result = call_as(User.find(1), 'create_issue',
                       'project' => 'ecookbook', 'subject' => 'Open child', 'parent_id' => 1)[:result]

      assert result[:isError]
      assert_match(/closed issue 1/, result[:content].first[:text])
      assert_nil Issue.find_by(subject: 'Open child')
    end
  end

  def test_create_issue_refuses_a_tracker_that_disables_the_parent_field
    tracker = Project.find_by!(identifier: 'ecookbook').trackers.first
    tracker.core_fields = tracker.core_fields - ['parent_issue_id']
    tracker.save!

    with_read_only_off do
      result = call_as(User.find(1), 'create_issue',
                       'project' => 'ecookbook', 'subject' => 'Disabled parent',
                       'tracker' => tracker.name, 'parent_id' => 1)[:result]

      assert result[:isError]
      assert_match(/does not allow a parent/, result[:content].first[:text])
      assert_nil Issue.find_by(subject: 'Disabled parent')
    end
  end

  private

  def grant_manage_subtasks_elsewhere(user)
    project = Project.where.not(identifier: 'ecookbook').where(status: Project::STATUS_ACTIVE).first
    assert project, 'fixture must include a second active project'
    role = Role.create!(name: "mcp-subtasks-#{user.id}",
                        permissions: [:manage_subtasks, :view_issues, :add_issues])
    membership = Member.find_or_initialize_by(user_id: user.id, project_id: project.id)
    membership.role_ids = (membership.role_ids + [role.id]).uniq
    membership.save!
  end

  def build_server(user)
    # available_to? clears oauth_scope and restores the value it was given, so
    # pass the caller's scopes or a narrowed token is wiped before the call.
    scopes = user.oauth_scope
    RedmineMcpPlugin::McpServer.build(
      tools: RedmineMcpPlugin::Registry.all.select { |tool| tool.available_to?(user, oauth_scopes: scopes) },
      server_context: { user: user, auth: { mode: scopes.nil? ? :api_key : :oauth2, scopes: scopes } }
    )
  end

  def call_as(user, name, arguments = {})
    build_server(user).handle(
      { jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: name, arguments: arguments } }
    )
  end

  def with_read_only_off
    Setting.plugin_redmine_mcp_plugin = RedmineMcpPlugin::Settings::DEFAULTS.merge('read_only' => '0')
    Setting.clear_cache
    yield
  ensure
    Setting.plugin_redmine_mcp_plugin = RedmineMcpPlugin::Settings::DEFAULTS.merge('read_only' => '1')
    Setting.clear_cache
  end
end
