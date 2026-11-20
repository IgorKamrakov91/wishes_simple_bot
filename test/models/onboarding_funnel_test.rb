require "test_helper"
require "mocha/minitest"

class OnboardingFunnelTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(telegram_id: 97801, first_name: "Owner")
  end

  test "onboarding depends on cohort and milestone rather than the presence of lists or gifts" do
    assert @user.onboarding?
    list = @user.wishlists.create!(title: "Birthday")
    refute @user.has_changes_to_save?
    assert @user.reload.onboarding?
    item = list.items.create!(title: "Book")
    refute @user.has_changes_to_save?
    refute @user.reload.onboarding?

    item.destroy!
    refute @user.reload.onboarding?, "deleting the first gift must not restart onboarding"
    @user.reset_onboarding!
    assert @user.onboarding?
    assert_equal 1, @user.wishlists.count

    @user.update!(onboarding_eligible: false)
    refute @user.onboarding?, "an empty legacy account is not a new user"
  end

  test "first list and item use the creation transaction and are never overwritten" do
    first_list = first_item = nil
    freeze_time do
      first_list = @user.wishlists.create!(title: "Birthday")
      first_item = first_list.items.create!(title: "Book")
      assert_equal Time.current, @user.reload.first_list_at
      assert_equal Time.current, @user.first_item_at
    end
    travel 1.hour do
      @user.wishlists.create!(title: "Other").items.create!(title: "Game")
      assert_equal first_list.created_at, @user.reload.first_list_at
      assert_equal first_item.created_at, @user.first_item_at
    end
  end

  test "rolled back saves leave no first list or first gift" do
    User.transaction do
      @user.wishlists.create!(title: "Cancelled").items.create!(title: "Book")
      raise ActiveRecord::Rollback
    end
    assert_nil @user.reload.first_list_at
    assert_nil @user.first_item_at
    assert @user.onboarding?

    list = @user.wishlists.create!(title: "Kept")
    Item.transaction do
      list.items.create!(title: "Cancelled")
      raise ActiveRecord::Rollback
    end
    assert_nil @user.reload.first_item_at
    assert @user.first_list_at
  end

  test "AI gifts record the same first item and repeated choices preserve it" do
    list = @user.wishlists.create!(title: "Birthday")
    suggestion = @user.gift_suggestions.create!(wishlist: list, status: "ready", ideas: [ { "title" => "Book" } ])
    _status, item = suggestion.add_idea!(@user, 0)
    assert_equal item.created_at, @user.reload.first_item_at
    travel 1.hour do
      assert_no_difference("Item.count") { suggestion.add_idea!(@user, 0) }
      assert_equal item.created_at, @user.reload.first_item_at
    end
  end

  test "a later tagged start preserves the first contact and first campaign" do
    @user.record_contact!(kind: "inline_query")
    contact_at = @user.first_contact_at
    travel 1.hour do
      @user.record_contact!(kind: "campaign_start", source: "winter", private_start: true)
      assert_equal "inline_query", @user.first_contact_kind
      assert_equal contact_at, @user.first_contact_at
      assert_equal Time.current, @user.first_private_start_at
      assert_equal "winter", @user.acquisition_source
    end
    start_at = @user.first_private_start_at
    travel 2.hours do
      @user.record_contact!(kind: "campaign_start", source: "another", private_start: true)
      assert_equal "winter", @user.acquisition_source
      assert_equal start_at, @user.first_private_start_at
    end
  end

  test "legacy accounts retain unknown contact and campaign attribution" do
    @user.update!(onboarding_eligible: false)
    @user.record_contact!(kind: "campaign_start", source: "winter", private_start: true)
    assert_nil @user.reload.first_contact_at
    assert_nil @user.first_contact_kind
    assert_nil @user.acquisition_source
    assert_nil @user.first_private_start_at
  end

  test "ordinary repeat contacts do not lock while optional milestones are still absent" do
    @user.record_contact!(kind: "inline_query")
    before = @user.attributes.slice(*OnboardingFunnel::FIELDS)
    User.any_instance.expects(:with_lock).never

    @user.record_contact!(kind: "message")
    @user.record_contact!(kind: "callback", source: "")

    assert_equal before, @user.reload.attributes.slice(*OnboardingFunnel::FIELDS)
  end

  test "repeat tagged private starts do not lock after all contact fields are saved" do
    @user.record_contact!(kind: "campaign_start", source: "winter", private_start: true)
    before = @user.attributes.slice(*OnboardingFunnel::FIELDS)
    User.any_instance.expects(:with_lock).never

    @user.record_contact!(kind: "campaign_start", source: "another", private_start: true)
    @user.record_contact!(kind: "start", private_start: true)

    assert_equal before, @user.reload.attributes.slice(*OnboardingFunnel::FIELDS)
  end

  test "the pending contact is rechecked after locking a stale instance" do
    winner = User.find(@user.id)
    winner.record_contact!(kind: "campaign_start", source: "winter", private_start: true)
    @user.expects(:update_columns).never

    @user.record_contact!(kind: "campaign_start", source: "another", private_start: true)

    assert_equal winner.first_contact_at, @user.first_contact_at
    assert_equal "winter", @user.acquisition_source
    assert_equal winner.first_private_start_at, @user.first_private_start_at
  end
end
