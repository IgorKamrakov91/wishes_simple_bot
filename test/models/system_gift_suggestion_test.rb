require "test_helper"
require "mocha/minitest"

class SystemGiftSuggestionTest < ActiveJob::TestCase
  setup do
    GiftSuggestion.stubs(:enabled?).returns(true)
    @user = User.create!(telegram_id: 97701)
    @list = @user.wishlists.create!(title: "Birthday")
  end

  test "automatic requests never enqueue the personal delivery job" do
    request = nil
    assert_no_enqueued_jobs do
      request = GiftSuggestion.request_system_for!(@user, @list)
    end
    assert_equal :created, request.status
    assert request.suggestion.system_generated?
  end

  test "a running system request doesn't block a personal one" do
    system = GiftSuggestion.request_system_for!(@user, @list).suggestion
    assert system.claim!
    personal = GiftSuggestion.request_for!(@user, @list)
    assert_equal :created, personal.status
    refute personal.suggestion.system_generated?
    system.finish!([ "Lamp" ])
  end

  test "system requests share the global cost cap including failed attempts" do
    GiftSuggestion.stubs(:global_daily_limit).returns(1)
    system = GiftSuggestion.request_system_for!(@user, @list).suggestion
    system.fail!("timeout")
    assert_equal :global_limit, GiftSuggestion.request_for!(@user, @list).status
    assert_equal :global_limit, GiftSuggestion.request_system_for!(@user, @list).status
    assert_equal 1, GiftSuggestion.count
  end

  test "disabled and foreign system requests cannot create suggestions" do
    other = User.create!(telegram_id: 97702)
    assert_no_difference("GiftSuggestion.count") do
      assert_raises(ActiveRecord::RecordNotFound) { GiftSuggestion.request_system_for!(other, @list) }
      GiftSuggestion.stubs(:enabled?).returns(false)
      assert_equal :disabled, GiftSuggestion.request_system_for!(@user, @list).status
    end
  end
end
