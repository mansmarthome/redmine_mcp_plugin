# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# Optional checklist and tag support must stay off the MCP surface unless the
# host plugin is loaded. These cases do not require either plugin.
class RedmineMcpPluginIntegrationsTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :members, :member_roles, :roles,
           :issues, :issue_statuses, :trackers, :enumerations, :enabled_modules

  Integrations = RedmineMcpPlugin::Integrations

  def setup
    Setting.plugin_redmine_mcp_plugin = RedmineMcpPlugin::Settings::DEFAULTS.merge('read_only' => '1')
    Setting.clear_cache
  end

  def teardown
    Setting.clear_cache
  end

  def test_checklists_are_absent_without_the_plugin
    skip 'checklists plugin is loaded' if Object.const_defined?(:Checklist)

    assert_not Integrations.checklists?
    assert_not_includes tool_names, 'update_issue_checklists'
    assert_not_includes tool_names, 'set_checklist_done'
  end

  def test_issue_tags_are_absent_without_the_plugin
    skip 'additional_tags is loaded' if defined?(AdditionalTags)

    assert_not Integrations.issue_tags?
    assert_not_includes tool_names, 'list_issue_tags'
    assert_not_includes tool_names, 'update_issue_tags'
  end

  def test_checklist_tools_are_registered_only_when_detected
    Integrations.stubs(:checklists?).returns(true)
    names = RedmineMcpPlugin::Registry.all.map(&:name_value)

    assert_includes names, 'update_issue_checklists'
    assert_includes names, 'set_checklist_done'
  end

  def test_tag_tools_are_registered_only_when_detected
    Integrations.stubs(:issue_tags?).returns(true)
    names = RedmineMcpPlugin::Registry.all.map(&:name_value)

    assert_includes names, 'list_issue_tags'
    assert_includes names, 'update_issue_tags'
  end

  def test_create_and_search_schemas_omit_optional_fields_without_plugins
    skip 'an optional integration is loaded' if Integrations.checklists? || Integrations.issue_tags?

    create_keys = schema_keys(RedmineMcpPlugin::Tools::CreateIssue)
    search_keys = schema_keys(RedmineMcpPlugin::Tools::SearchIssues)

    assert_not_includes create_keys, 'checklists'
    assert_not_includes create_keys, 'tags'
    assert_not_includes search_keys, 'tags'
  end

  def test_search_schema_offers_tags_when_issue_tags_are_detected
    Integrations.stubs(:issue_tags?).returns(true)

    assert_includes schema_keys(RedmineMcpPlugin::Tools::SearchIssues), 'tags'
  end

  def test_get_issue_omits_optional_keys_without_plugins
    skip 'an optional integration is loaded' if Integrations.checklists? || Integrations.issue_tags?

    payload = call_get_issue
    assert_not payload.key?(:checklists)
    assert_not payload.key?(:tags)
  end

  def test_checklist_journal_details_stay_hidden_without_view_permission
    detail = Struct.new(:property, :prop_key).new('attr', 'checklist')
    issue = Issue.find(1)
    user = User.find(2)
    Integrations.stubs(:checklists?).returns(true)
    user.stubs(:allowed_to?).returns(false)
    assert Integrations.hide_journal_detail?(issue, detail, user)

    Integrations.stubs(:checklists?).returns(false)
    assert_not Integrations.hide_journal_detail?(issue, detail, user)
  end

  def test_optional_write_tools_stay_hidden_while_read_only
    Integrations.stubs(:checklists?).returns(true)
    Integrations.stubs(:issue_tags?).returns(true)
    user = User.find(1)
    user.stubs(:allowed_to?).returns(true)

    assert_not RedmineMcpPlugin::Tools::UpdateIssueChecklists.available_to?(user, oauth_scopes: nil)
    assert_not RedmineMcpPlugin::Tools::UpdateIssueTags.available_to?(user, oauth_scopes: nil)
  end

  def test_tag_permission_check_does_not_require_tags_allowed_for
    issue = Issue.new(project: Project.find(1))
    user = User.find(1)

    assert_includes [true, false], RedmineMcpPlugin::Integrations::IssueTags.allowed?(issue, user, %w[First])
  end

  def test_unrelated_journal_details_are_not_hidden
    detail = Struct.new(:property, :prop_key).new('attr', 'status_id')
    assert_not Integrations.hide_journal_detail?(Issue.find(1), detail, User.find(1))
  end

  private

  def tool_names
    RedmineMcpPlugin::Registry.all.map(&:name_value)
  end

  def schema_keys(tool)
    tool.input_schema_value.to_h[:properties].keys.map(&:to_s)
  end

  def call_get_issue
    user = User.find(1)
    server = RedmineMcpPlugin::McpServer.build(
      tools: RedmineMcpPlugin::Registry.all.select { |tool| tool.available_to?(user, oauth_scopes: nil) },
      server_context: { user: user, auth: { mode: :api_key } }
    )
    result = server.handle(
      { jsonrpc: '2.0', id: 1, method: 'tools/call',
        params: { name: 'get_issue', arguments: { id: 1, include_journals: false } } }
    )
    assert_not result[:result][:isError]
    result[:result][:structuredContent]
  end
end
