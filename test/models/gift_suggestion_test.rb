require "test_helper"
require "mocha/minitest"

class GiftSuggestionTest < ActiveJob::TestCase
  KEYS = %w[YANDEX_AI_API_KEY YANDEX_AI_FOLDER_ID YANDEX_AI_ENABLED YANDEX_AI_DAILY_LIMIT].freeze

  setup do
    @previous_env = KEYS.to_h { |key| [ key, ENV[key] ] }
    set_env("YANDEX_AI_API_KEY" => "key", "YANDEX_AI_FOLDER_ID" => "folder", "YANDEX_AI_ENABLED" => nil, "YANDEX_AI_DAILY_LIMIT" => nil)
    @owner = User.create!(telegram_id: 97001, first_name: "Owner")
    @guest = User.create!(telegram_id: 97002, first_name: "Guest")
    @wishlist = @owner.wishlists.create!(title: "Birthday")
    @wishlist.admit!(@guest)
  end

  teardown do
    set_env(@previous_env)
  end

  test "disabled without keys or with the switch off" do
    set_env("YANDEX_AI_API_KEY" => nil)
    refute GiftSuggestion.enabled?
    assert_equal :disabled, GiftSuggestion.request_for!(@owner, @wishlist).status

    set_env("YANDEX_AI_API_KEY" => "key", "YANDEX_AI_ENABLED" => "false")
    refute GiftSuggestion.enabled?
  end

  test "a request enqueues one job and a second press while it runs returns the same request" do
    first = nil
    assert_enqueued_jobs 1, only: GiftIdeasJob do
      first = GiftSuggestion.request_for!(@owner, @wishlist)
      assert_equal :active, GiftSuggestion.request_for!(@owner, @wishlist).status
    end
    assert_equal :created, first.status
    assert_equal "pending", first.suggestion.status
  end

  test "only the owner can ask for ideas for a list" do
    assert_raises(ActiveRecord::RecordNotFound) { GiftSuggestion.request_for!(@guest, @wishlist) }
  end

  test "two ready sets a day per person, counted in Moscow time" do
    2.times do |index|
      request = GiftSuggestion.request_for!(@owner, @wishlist)
      assert_equal :created, request.status
      request.suggestion.finish!([ "Lamp" ])
      assert_equal 1 - index, GiftSuggestion.remaining_requests_for(@owner)
    end

    assert_equal :user_limit, GiftSuggestion.request_for!(@owner, @wishlist).status

    travel_to Time.current.in_time_zone("Europe/Moscow").tomorrow.beginning_of_day + 1.minute do
      assert_equal 2, GiftSuggestion.remaining_requests_for(@owner)
      assert_equal :created, GiftSuggestion.request_for!(@owner, @wishlist).status
    end
  end

  test "failed requests restore the personal quota and permit more than two attempts" do
    %w[timeout no_ideas disabled].each do |code|
      request = GiftSuggestion.request_for!(@owner, @wishlist)
      assert_equal :created, request.status
      assert_equal 1, GiftSuggestion.remaining_requests_for(@owner)
      assert_equal :active, GiftSuggestion.request_for!(@owner, @wishlist).status
      request.suggestion.fail!(code)
      assert_equal 2, GiftSuggestion.remaining_requests_for(@owner)
    end
    assert_equal :created, GiftSuggestion.request_for!(@owner, @wishlist).status
  end

  test "stale pending and processing requests do not consume the personal quota" do
    travel_to Time.utc(2026, 11, 9, 12) do
      ready_suggestion([ "Lamp" ]).update!(created_at: 10.minutes.ago)
      GiftSuggestion.create!(user: @owner, wishlist: @wishlist, created_at: 3.minutes.ago)
      GiftSuggestion.create!(user: @owner, wishlist: @wishlist, status: "processing",
                             created_at: 10.minutes.ago, started_at: 3.minutes.ago)

      assert_equal 1, GiftSuggestion.remaining_requests_for(@owner)
      assert_equal :created, GiftSuggestion.request_for!(@owner, @wishlist).status
      assert_equal 0, GiftSuggestion.remaining_requests_for(@owner)
      assert_equal :active, GiftSuggestion.request_for!(@owner, @wishlist).status
    end
  end

  test "active processing uses started_at and becomes stale only after the cutoff" do
    travel_to Time.utc(2026, 11, 9, 12) do
      request = GiftSuggestion.create!(user: @owner, wishlist: @wishlist, status: "processing",
                                       created_at: 10.minutes.ago, started_at: 1.minute.ago)
      GiftSuggestion.create!(user: @owner, wishlist: @wishlist, created_at: 3.minutes.ago)
      assert_equal 1, GiftSuggestion.remaining_requests_for(@owner)
      assert_equal :active, GiftSuggestion.request_for!(@owner, @wishlist).status

      travel 1.minute
      refute request.stale?
      assert_equal 1, GiftSuggestion.remaining_requests_for(@owner)
      assert_equal :active, GiftSuggestion.request_for!(@owner, @wishlist).status

      travel 1.second
      assert request.stale?
      assert_equal 2, GiftSuggestion.remaining_requests_for(@owner)
      assert_equal :created, GiftSuggestion.request_for!(@owner, @wishlist).status
    end
  end

  test "the app-wide daily limit stops everyone" do
    set_env("YANDEX_AI_DAILY_LIMIT" => "1")
    GiftSuggestion.request_for!(@owner, @wishlist).suggestion.fail!("x")
    other = User.create!(telegram_id: 97003, first_name: "Other")

    assert_equal 2, GiftSuggestion.remaining_requests_for(@owner)
    assert_equal :global_limit, GiftSuggestion.request_for!(@owner, @wishlist).status
    assert_equal :global_limit, GiftSuggestion.request_for!(other, other.wishlists.create!(title: "List")).status
  end

  test "stale requests still consume the global cost cap" do
    set_env("YANDEX_AI_DAILY_LIMIT" => "1")
    GiftSuggestion.request_for!(@owner, @wishlist)
    travel 3.minutes do
      assert_equal 2, GiftSuggestion.remaining_requests_for(@owner)
      assert_equal :global_limit, GiftSuggestion.request_for!(@owner, @wishlist).status
    end
  end

  test "a stuck request stops blocking new ones" do
    stuck = GiftSuggestion.request_for!(@owner, @wishlist).suggestion
    travel 3.minutes do
      assert stuck.reload.failed?
      assert_equal :created, GiftSuggestion.request_for!(@owner, @wishlist).status
    end
  end

  test "a job claims a request once" do
    suggestion = GiftSuggestion.request_for!(@owner, @wishlist).suggestion
    assert suggestion.claim!
    refute suggestion.claim!
  end

  test "adding an idea creates one gift; repeats and existing titles give the existing gift" do
    suggestion = ready_suggestion([ "Лампа для чтения", "Плед" ])
    @wishlist.items.create!(title: "плед")

    status, item = suggestion.add_idea!(@owner, 0)
    assert_equal :added, status
    assert_equal "Лампа для чтения", item.title
    assert_nil item.url

    assert_no_difference("Item.count") do
      assert_equal [ :already, item ], suggestion.reload.add_idea!(@owner, 0)
      assert_equal :already, suggestion.add_idea!(@owner, 1).first
    end
    assert_equal item.id, suggestion.reload.ideas[0]["item_id"]
  end

  test "a deleted gift is not silently recreated, and others can't add ideas" do
    suggestion = ready_suggestion([ "Лампа для чтения" ])
    _, item = suggestion.add_idea!(@owner, 0)
    item.destroy!

    assert_no_difference("Item.count") do
      assert_equal :gone, suggestion.reload.add_idea!(@owner, 0).first
      assert_equal :unavailable, suggestion.add_idea!(@guest, 0).first
      assert_equal :unavailable, suggestion.add_idea!(@owner, 5).first
    end
  end

  test "earlier ideas for the same list are remembered for three days, newest first" do
    other_list = @owner.wishlists.create!(title: "Other")
    oldest = ready_suggestion([ "Старая" ])
    oldest.update_columns(created_at: 4.days.ago)
    ready_suggestion([ "Лампа", "Плед" ]).update_columns(created_at: 2.days.ago)
    ready_suggestion([ "Кружка", "Лампа" ])
    GiftSuggestion.create!(user: @owner, wishlist: @wishlist, status: "failed")
    GiftSuggestion.create!(user: @owner, wishlist: other_list, status: "ready",
                           ideas: [ { "title" => "Чужая", "item_id" => nil } ])
    current = GiftSuggestion.create!(user: @owner, wishlist: @wishlist)

    assert_equal [ "Кружка", "Лампа", "Плед" ], current.previous_titles
  end

  test "cleanup removes requests older than three days" do
    old = ready_suggestion([ "A" ])
    old.update_columns(created_at: 4.days.ago)
    recent = ready_suggestion([ "B" ])

    CleanupGiftSuggestionsJob.perform_now

    refute GiftSuggestion.exists?(old.id)
    assert GiftSuggestion.exists?(recent.id)
  end

  private

  def set_env(values)
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def ready_suggestion(titles)
    GiftSuggestion.create!(user: @owner, wishlist: @wishlist).tap { |suggestion| suggestion.finish!(titles) }
  end
end
