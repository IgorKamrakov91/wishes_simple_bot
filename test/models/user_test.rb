require "test_helper"
require "mocha/minitest"

class UserTest < ActiveSupport::TestCase
  test "full_name returns first and last name when present" do
    user = User.new(first_name: "John", last_name: "Doe", username: "johndoe")
    assert_equal "John Doe", user.full_name
  end

  test "full_name returns first name when last name is missing" do
    user = User.new(first_name: "John", username: "johndoe")
    assert_equal "John", user.full_name
  end

  test "full_name returns username when names are missing" do
    user = User.new(username: "johndoe")
    assert_equal "johndoe", user.full_name
  end

  test "full_name returns Anonymous when all are missing" do
    user = User.new
    assert_equal "Anonymous", user.full_name
  end

  test "find_or_create_from_telegram creates a user from Telegram data" do
    freeze_time do
      user = User.find_or_create_from_telegram(
        id: 42,
        username: "gift_finder",
        first_name: "Gift",
        last_name: "Finder"
      )

      assert user.persisted?
      assert_equal 42, user.telegram_id
      assert_equal "gift_finder", user.username
      assert_equal "Gift", user.first_name
      assert_equal "Finder", user.last_name
      assert_equal Time.current, user.last_seen_at
    end
  end

  test "a first update losing the validation race refreshes the winner without clearing its draft" do
    winner = User.create!(telegram_id: 43, first_name: "Old", bot_state: "creating_list", bot_payload: {},
                          notify_birthdays: false)
    stale = User.new(telegram_id: 43)
    User.expects(:find_or_initialize_by).with(telegram_id: 43).returns(stale)

    result = User.find_or_create_from_telegram(id: 43, first_name: "New", username: "updated")

    assert_equal winner.id, result.id
    assert_equal "New", winner.reload.first_name
    assert_equal "updated", winner.username
    assert_equal "creating_list", winner.bot_state
    assert_equal({}, winner.bot_payload)
    refute winner.notify_birthdays
  end

  test "invalid Telegram identity still raises validation errors" do
    assert_raises(ActiveRecord::RecordInvalid) { User.find_or_create_from_telegram(first_name: "Guest") }
  end

  test "find_or_create_from_telegram refreshes existing profile details" do
    user = User.create!(telegram_id: 42, username: "old_name", first_name: "Old")

    travel_to 1.hour.from_now do
      same_user = User.find_or_create_from_telegram(
        id: 42,
        username: "new_name",
        first_name: "New",
        last_name: "Name"
      )

      assert_equal user.id, same_user.id
      assert_equal "new_name", user.reload.username
      assert_equal "New", user.first_name
      assert_equal "Name", user.last_name
      assert_equal Time.current, user.last_seen_at
    end
  end
end
