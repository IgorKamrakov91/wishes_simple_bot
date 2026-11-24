require "test_helper"
require "mocha/minitest"

class AiCallTest < ActiveSupport::TestCase
  KEYS = %w[YANDEX_AI_API_KEY YANDEX_AI_FOLDER_ID YANDEX_AI_ENABLED YANDEX_AI_DAILY_LIMIT YANDEX_AI_PHOTO_DAILY_LIMIT].freeze

  setup do
    @previous_env = KEYS.to_h { |key| [ key, ENV[key] ] }
    set_env("YANDEX_AI_API_KEY" => "key", "YANDEX_AI_FOLDER_ID" => "folder", "YANDEX_AI_ENABLED" => nil,
            "YANDEX_AI_DAILY_LIMIT" => nil, "YANDEX_AI_PHOTO_DAILY_LIMIT" => nil)
    @user = User.create!(telegram_id: 99_101, first_name: "Ann")
    @other = User.create!(telegram_id: 99_102, first_name: "Bob")
  end

  teardown { set_env(@previous_env) }

  test "a photo call is recorded while every cap allows it" do
    assert_difference("AiCall.count") { assert_equal :created, AiCall.reserve!(@user, :photo) }
    assert_equal "photo", AiCall.last.kind
  end

  test "nothing is recorded when AI is switched off" do
    set_env("YANDEX_AI_ENABLED" => "false")
    assert_no_difference("AiCall.count") { assert_equal :disabled, AiCall.reserve!(@user, :photo) }
  end

  test "one person gets a limited number of photos a day; others still can" do
    AiCall::KINDS["photo"][:per_user].times { AiCall.create!(user: @user, kind: "photo") }
    assert_equal :user_limit, AiCall.reserve!(@user, :photo)
    assert_equal :created, AiCall.reserve!(@other, :photo)
  end

  test "yesterday's calls don't count" do
    AiCall::KINDS["photo"][:per_user].times { AiCall.create!(user: @user, kind: "photo", created_at: 1.day.ago - 1.hour) }
    assert_equal :created, AiCall.reserve!(@user, :photo)
  end

  test "photos have their own app-wide cap" do
    set_env("YANDEX_AI_PHOTO_DAILY_LIMIT" => "1")
    AiCall.create!(user: @other, kind: "photo")
    assert_equal :kind_limit, AiCall.reserve!(@user, :photo)
  end

  test "photos and gift ideas share one daily cap" do
    set_env("YANDEX_AI_DAILY_LIMIT" => "2")
    list = @user.wishlists.create!(title: "Birthday")
    GiftIdeasJob.stubs(:perform_later)

    assert_equal :created, GiftSuggestion.request_for!(@user, list).status
    assert_equal :created, AiCall.reserve!(@other, :photo)
    assert_equal :global_limit, AiCall.reserve!(@other, :photo)
    GiftSuggestion.where(user: @user).update_all(status: "ready")
    assert_equal :global_limit, GiftSuggestion.request_for!(@user, list).status
  end

  private

  def set_env(values)
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
