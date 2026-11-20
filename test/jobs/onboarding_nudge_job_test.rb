require "test_helper"
require "mocha/minitest"
require "telegram/bot"

Telegram::Bot::Types::Update

class OnboardingNudgeJobTest < ActiveJob::TestCase
  setup do
    travel_to Time.utc(2026, 11, 21, 15) # 18:00 in Moscow
    @previous_token = ENV["TELEGRAM_BOT_TOKEN"]
    ENV["TELEGRAM_BOT_TOKEN"] = "local-onboarding-test"
    @user = User.create!(telegram_id: 97711, first_name: "Private Name", first_private_start_at: 25.hours.ago,
                         last_seen_at: 25.hours.ago)
    @list = @user.wishlists.create!(title: "Новый год <&>")
    @nudge = OnboardingNudge.create!(user: @user, locale: "ru")
    @messages = []
    @api = Object.new
    messages = @messages
    @api.define_singleton_method(:send_message) { |**params| messages << params }
    @api.stubs(:answer_callback_query)
    @api.stubs(:edit_message_text)
    Telegram::Bot::Client.stubs(:new).returns(stub(api: @api))
    GiftSuggestion.stubs(:enabled?).returns(true)
    @generator = mock("GiftIdeas")
    @generator.stubs(:call).returns([ "Настольная игра", "Лампа", "Термокружка" ])
    YandexAi::GiftIdeas.stubs(:new).returns(@generator)
  end

  teardown do
    ENV["TELEGRAM_BOT_TOKEN"] = @previous_token
    travel_back
  end

  test "the empty-list nudge saves system ideas before sending and is sent once" do
    @generator.expects(:call).once.with(@list.title, []).returns([ "Идея <&>", "Лампа", "Пазл" ])
    @api.expects(:send_message).once.with do |params|
      @messages.replace([ params ])
      @nudge.reload.prepared_at && @nudge.ideas == [ "Идея <&>", "Лампа", "Пазл" ] && params[:link_preview_options].is_disabled
    end
    2.times { deliver }

    assert @nudge.reload.sent_at
    assert_equal 1, @nudge.attempts
    assert @nudge.gift_suggestion.system_generated?
    assert_includes @messages.sole[:text], "Новый год &lt;&amp;&gt;"
    assert_includes @messages.sole[:text], "Идея &lt;&amp;&gt;"
    refute_includes @messages.sole[:text], "Private Name"
    assert_includes callbacks, "first_gift:#{@list.id}"
    assert_includes callbacks, "show_gift_ideas:#{@nudge.gift_suggestion_id}"
    assert_includes callbacks, "set_setting:notify_onboarding:0"
  end

  test "a user without a list gets saved examples and can begin a list" do
    @list.destroy!
    @generator.expects(:call).never
    assert_no_difference("GiftSuggestion.count") { deliver }
    assert_equal @nudge.fallback, @nudge.reload.ideas
    assert_includes callbacks, "new_list"
    assert_includes @messages.sole[:text], I18n.t("bot.onboarding_nudge.no_list")
  end

  test "disabled AI falls back to three saved examples" do
    @generator.expects(:call).never
    GiftSuggestion.stubs(:enabled?).returns(false)
    deliver
    assert_equal 3, @nudge.reload.ideas.size
    assert_equal @nudge.fallback, @nudge.ideas
    assert_empty GiftSuggestion.all
  end

  test "an exhausted global cap uses fixed examples without an API request" do
    GiftSuggestion.stubs(:global_daily_limit).returns(0)
    @generator.expects(:call).never
    deliver
    assert_equal @nudge.fallback, @nudge.reload.ideas
    assert_empty GiftSuggestion.all
  end

  test "a failed AI call is counted only in the global budget and not retried" do
    @generator.expects(:call).once.raises(YandexAi::Client::Error.new("timeout"))
    2.times { deliver }
    assert_equal @nudge.fallback, @nudge.reload.ideas
    assert_equal "failed", @nudge.gift_suggestion.status
    assert_equal 1, GiftSuggestion.today.count
  end

  test "activity postpones delivery until 24 hours later and the Moscow opening" do
    @user.update!(last_seen_at: Time.current)
    @generator.expects(:call).never
    deliver
    assert_empty @messages
    assert_equal 24.hours.from_now, @nudge.reload.retry_at
    assert_nil @nudge.preparing_at
  end

  test "night delivery moves to the next evening without spending an AI request" do
    travel_to Time.utc(2026, 11, 21, 17) # 20:00 Moscow
    @generator.expects(:call).never
    deliver
    assert_equal Time.utc(2026, 11, 22, 15), @nudge.reload.retry_at
    assert_empty @messages
    assert_empty GiftSuggestion.all
  end

  test "daytime delivery waits for the evening window" do
    travel_to Time.utc(2026, 11, 22, 9) # 12:00 Moscow, other reminders are open
    @generator.expects(:call).never
    deliver
    assert_equal Time.utc(2026, 11, 22, 15), @nudge.reload.retry_at
    assert_empty @messages
  end

  test "new gifts opt-out legacy users and inline-only contacts suppress queued nudges" do
    @generator.expects(:call).never
    states = [ { notify_onboarding: false }, { onboarding_eligible: false }, { first_private_start_at: nil }, { first_item_at: Time.current } ]
    original = @user.attributes.symbolize_keys.slice(:notify_onboarding, :onboarding_eligible, :first_private_start_at, :first_item_at)
    states.each do |state|
      @user.update_columns(original.merge(state))
      deliver
    end
    assert_empty @messages
    assert_nil @nudge.reload.preparing_at
  end

  test "a gift saved while AI runs cancels delivery without overwriting input" do
    @generator.expects(:call).once.with do |*_|
      @list.items.create!(title: "Already chosen")
      @user.update!(bot_state: "editing_item", bot_payload: { "item_id" => @list.items.sole.id, "field" => "price" })
      true
    end.returns([ "Лампа" ])
    deliver
    assert_empty @messages
    assert_equal "editing_item", @user.reload.bot_state
    assert @nudge.reload.prepared_at
    assert_nil @nudge.sent_at
  end

  test "activity during AI generation postpones and reuses saved ideas" do
    @generator.expects(:call).once.with do |*_|
      @user.update!(last_seen_at: Time.current)
      true
    end.returns([ "Лампа" ])
    deliver
    assert_empty @messages
    assert @nudge.reload.prepared_at
    travel 24.hours do
      deliver
    end
    assert_equal 1, @messages.size
    assert_equal [ "Лампа" ], @nudge.reload.ideas
  end

  test "a changed or deleted target never opens the old list or regenerates" do
    @generator.expects(:call).once.with do |*_|
      @list.destroy!
      true
    end.returns([ "Лампа" ])
    deliver
    refute_includes callbacks, "first_gift:#{@list.id}"
    refute callbacks.any? { |value| value&.start_with?("show_gift_ideas:") }
    assert_includes callbacks, "new_list"
    refute_includes @messages.sole[:text], "Новый год"
    assert_equal @nudge.fallback, @nudge.reload.ideas
  end

  test "continuation resumes an existing draft instead of changing it" do
    @user.update!(bot_state: "adding_item_title", bot_payload: { "wishlist_id" => @list.id, "url" => "https://example.com/gift" })
    before = @user.bot_payload
    deliver
    assert_includes callbacks, "resume_input"
    assert_equal before, @user.reload.bot_payload
    assert_equal "adding_item_title", @user.bot_state
  end

  test "duplicate delivery during the Telegram request cannot send twice" do
    @api.expects(:send_message).once.with { |_params| deliver; true }
    2.times { deliver }
    assert @nudge.reload.sent_at
    assert_equal 1, @nudge.attempts
  end

  test "known rejected deliveries reuse ideas with bounded retries" do
    @generator.expects(:call).once.returns([ "Лампа" ])
    @api.expects(:send_message).times(3).raises(response_error(429, parameters: { "retry_after" => 60 }))
    4.times do
      deliver
      travel 61.seconds
    end
    assert_equal 3, @nudge.reload.attempts
    assert_nil @nudge.sent_at
    assert_equal [ "Лампа" ], @nudge.ideas
  end

  test "403 ends delivery attempts" do
    @api.expects(:send_message).once.raises(response_error(403))
    2.times { deliver }
    assert @nudge.reload.claimed_at
    assert_equal 1, @nudge.attempts
  end

  test "an uncertain timeout never sends or generates twice" do
    @generator.expects(:call).once.returns([ "Лампа" ])
    @api.expects(:send_message).once.raises(Faraday::TimeoutError)
    2.times { deliver }
    assert @nudge.reload.claimed_at
    assert_nil @nudge.sent_at
  end

  test "lost generation recovers saved answers or examples without calling AI again" do
    @nudge.update!(preparing_at: 3.minutes.ago)
    @generator.expects(:call).never
    deliver
    assert_equal @nudge.fallback, @nudge.reload.ideas
    assert @nudge.sent_at
  end

  test "a ready answer persisted before a worker crash is reused" do
    request = GiftSuggestion.create!(user: @user, wishlist: @list, system_generated: true, status: "ready",
                                    ideas: [ { "title" => "Saved idea" } ])
    @nudge.update!(preparing_at: 3.minutes.ago, wishlist: @list, gift_suggestion: request)
    @generator.expects(:call).never
    deliver
    assert_equal [ "Saved idea" ], @nudge.reload.ideas
  end

  test "a live generation claim does not issue a second request or send early" do
    @nudge.update!(preparing_at: Time.current)
    @generator.expects(:call).never
    deliver
    assert_empty @messages
    assert_nil @nudge.reload.prepared_at
  end

  test "the captured locale controls fallback and resetting the funnel cannot resend" do
    @nudge.update!(locale: "en")
    GiftSuggestion.stubs(:enabled?).returns(false)
    deliver
    assert_equal I18n.t("bot.onboarding_nudge.examples", locale: :en), @nudge.reload.ideas
    assert_includes @messages.sole[:text], "Your list"
    @user.reset_onboarding!
    @user.record_contact!(kind: "start", private_start: true)
    travel 2.days do
      deliver
    end
    assert_equal 1, @messages.size
  end

  test "the dismiss button changes only this user's preference and keeps a draft" do
    deliver
    @user.update!(bot_state: "adding_item_title", bot_payload: { "wishlist_id" => @list.id, "url" => "https://example.com/gift" })
    other = User.create!(telegram_id: 97712)
    callback = Telegram::Bot::Types::CallbackQuery.new(
      id: "dismiss", chat_instance: "chat", data: "set_setting:notify_onboarding:0",
      from: { id: @user.telegram_id, is_bot: false, first_name: "Owner" },
      message: { message_id: 1, date: 1, chat: { id: @user.telegram_id, type: "private" }, text: "Nudge" }
    )
    Bot::Callbacks.handle(stub(api: @api), callback)
    refute @user.reload.notify_onboarding?
    assert other.reload.notify_onboarding?
    assert_equal "adding_item_title", @user.bot_state
    assert_equal "https://example.com/gift", @user.bot_payload["url"]
  end

  private

  def deliver
    OnboardingNudgeJob.perform_now(@nudge.id)
  end

  def callbacks
    @messages.last[:reply_markup].inline_keyboard.flatten.map(&:callback_data)
  end

  def response_error(code, **extra)
    body = { "ok" => false, "error_code" => code, "description" => "Delivery failed" }.merge(extra.stringify_keys)
    Telegram::Bot::Exceptions::ResponseError.new(response: stub(status: code, body: body.to_json))
  end
end
