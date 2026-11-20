require "test_helper"
require "rake"

class OnboardingRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("onboarding:reset")
    @task = Rake::Task["onboarding:reset"]
    @task.reenable
    @owner = User.create!(telegram_id: 797229231, first_name: "Owner", onboarding_eligible: false,
                          bot_state: "adding_item_url", bot_payload: { "title" => "Draft" })
    @list = @owner.wishlists.create!(title: "Birthday")
    @item = @list.items.create!(title: "Kept")
    @other = User.create!(telegram_id: 97802, first_name: "Other")
    @other.wishlists.create!(title: "Other list").items.create!(title: "Other gift")
  end

  test "reset changes only the named user's funnel and prints both snapshots" do
    @owner.update!(first_contact_at: 1.day.ago, first_contact_kind: "start", acquisition_source: "winter",
                   first_private_start_at: 1.day.ago, first_share_query_at: 1.hour.ago,
                   first_shared_list_open_at: 1.hour.ago)
    untouched = @owner.attributes.except(*OnboardingFunnel::FIELDS)
    other = @other.reload.attributes
    list = @list.attributes
    item = @item.attributes
    output, = capture_io { @task.invoke(@owner.telegram_id.to_s) }

    assert_includes output, "Before:"
    assert_includes output, "After:"
    assert_includes output, @owner.telegram_id.to_s
    assert_includes output, "winter"
    assert_equal untouched, @owner.reload.attributes.except(*OnboardingFunnel::FIELDS)
    assert @owner.onboarding?
    OnboardingFunnel::FIELDS.excluding("onboarding_eligible").each { |field| assert_nil @owner[field], field }
    assert_equal other, @other.reload.attributes
    assert_equal list, @list.reload.attributes
    assert_equal item, @item.reload.attributes
  end

  test "missing malformed and unknown IDs never reset anyone" do
    before = User.order(:id).map(&:attributes)
    [ nil, "", "0", "-1", "797229231 extra", "1 OR 1=1", "999999999" ].each do |id|
      @task.reenable
      capture_io do
        error = assert_raises(SystemExit) { @task.invoke(id) }
        refute error.success?
      end
    end
    assert_equal before, User.order(:id).map(&:attributes)
  end
end
