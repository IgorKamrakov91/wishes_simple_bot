require "test_helper"
require "mocha/minitest"
require "telegram/bot"

Telegram::Bot::Types::Update

class BotOnboardingIdeasTest < ActiveJob::TestCase
  setup do
    GiftSuggestion.stubs(:enabled?).returns(true)
    @owner = User.create!(telegram_id: 97601, first_name: "Owner")
    @list = @owner.wishlists.create!(title: "Birthday")
    @owner.update!(bot_state: "adding_item", bot_payload: { "wishlist_id" => @list.id, "first_item" => true })
    @screens = []
    @api = stub
    @api.stubs(:send_message).with { |params| @screens << params; true }
    @api.stubs(:edit_message_text).with do |params|
      if @delivery_error
        error, @delivery_error = @delivery_error, nil
        raise error
      end
      @screens << params
      true
    end
    @api.stubs(:answer_callback_query).with { |params| @answer = params; true }
    @bot = stub(api: @api)
    @update_id = 9_760_100
  end

  test "the first gift prompt shows ideas without a quota in both locales" do
    %i[ru en].each do |locale|
      I18n.with_locale(locale) do
        assert_no_difference("GiftSuggestion.count") { press("resume_input") }
        assert_includes callbacks, "gift_ideas:#{@list.id}"
        button = buttons.find { |entry| entry.callback_data == "gift_ideas:#{@list.id}" }
        assert_equal I18n.t("bot.gift_ideas.onboarding_button"), button.text
      end
    end
    suggestion = ready_suggestion
    press("resume_input")
    assert_includes callbacks, "show_gift_ideas:#{suggestion.id}"
  end

  test "requesting twice keeps empty input and renders waiting alongside the manual prompt" do
    before = @owner.bot_payload
    assert_enqueued_jobs 1, only: GiftIdeasJob do
      assert_difference("GiftSuggestion.count", 1) do
        2.times { press("gift_ideas:#{@list.id}") }
      end
    end
    assert_equal before, @owner.reload.bot_payload
    assert_equal "adding_item", @owner.bot_state
    assert_includes text, I18n.t("bot.gift_ideas.requests.active")
    assert_includes text, I18n.t("bot.messages.first_item_prompt", list: @list.title)

    say("My own idea")
    assert_equal "My own idea", @list.items.sole.title
    assert_nil @owner.reload.bot_state
  end

  test "an AI choice finishes only its own empty input and recovers the first gift screen after a timeout" do
    suggestion = ready_suggestion
    update = callback_update("add_idea:#{suggestion.id}:0")
    @delivery_error = Faraday::TimeoutError.new

    assert_difference("Item.count", 1) { dispatch(update) }
    assert_nil @owner.reload.bot_state
    item = @list.items.sole
    assert_equal item.created_at, @owner.first_item_at
    assert_equal "first_gift_added", BotUpdateReceipt.find(update.update_id).result_kind
    assert_nil BotUpdateReceipt.find(update.update_id).delivered_at

    assert_no_difference("Item.count") { dispatch(update) }
    assert BotUpdateReceipt.find(update.update_id).delivered_at
    assert_equal Bot::Inline.share_query(@list), buttons.first.switch_inline_query_chosen_chat.query
    assert_includes callbacks, "edit_item_field:url:#{item.id}"
    assert_no_difference("Item.count") { press("add_idea:#{suggestion.id}:0") }
  end

  test "a first gift choice also accepts empty input without a first_item prompt marker" do
    @owner.start_adding_item!(wishlist_id: @list.id)
    suggestion = ready_suggestion
    press("add_idea:#{suggestion.id}:0")

    assert_equal "Lamp", @list.items.sole.title
    assert_nil @owner.reload.bot_state
  end

  test "typed and unrelated drafts survive a late AI choice" do
    suggestion = ready_suggestion
    other = @owner.wishlists.create!(title: "Other")
    states = [
      [ "adding_item", { "wishlist_id" => other.id, "first_item" => true } ],
      [ "adding_item_title", { "wishlist_id" => @list.id, "url" => "https://example.com/gift" } ],
      [ "adding_item_url", { "wishlist_id" => @list.id, "title" => "Typed", "draft_id" => "d123" } ],
      [ "adding_item", { "wishlist_id" => @list.id, "title" => "Typed" } ],
      [ "creating_list", {} ]
    ]
    states.each do |state, payload|
      @owner.update!(bot_state: state, bot_payload: payload)
      assert_no_difference("Item.count") { press("add_idea:#{suggestion.id}:0") }
      assert_equal state, @owner.reload.bot_state
      assert_equal payload, @owner.bot_payload
      assert_equal I18n.t("bot.gift_ideas.finish_input"), @answer[:text]
    end
  end

  test "a stale user snapshot is rechecked after a manual URL arrives" do
    suggestion = ready_suggestion
    stale = User.find(@owner.id)
    url = "https://example.com/my-choice"
    say(url)
    context = Bot::Context.new(bot: @bot, user: stale, source: callback_update("noop").callback_query)

    assert_no_difference("Item.count") do
      Bot::Callbacks::GiftIdeasHandler.new(context).add_idea(suggestion.id, 0)
    end
    assert_equal "adding_item_title", @owner.reload.bot_state
    assert_equal url, @owner.bot_payload.fetch("url")
    say("My choice")
    assert_equal url, @list.items.sole.url
  end

  test "unready invalid and expired choices do not finish the empty input" do
    suggestion = ready_suggestion
    before = @owner.bot_payload
    suggestion.update!(status: "processing")
    assert_no_difference("Item.count") { press("add_idea:#{suggestion.id}:0") }
    suggestion.update!(status: "ready")
    assert_no_difference("Item.count") { press("add_idea:#{suggestion.id}:9") }
    suggestion.update!(created_at: 3.days.ago)
    assert_no_difference("Item.count") { press("add_idea:#{suggestion.id}:0") }

    assert_equal "adding_item", @owner.reload.bot_state
    assert_equal before, @owner.bot_payload
    assert_includes callbacks, "resume_input"
  end

  test "earlier sets don't limit requests, and the global cap leaves the manual route usable" do
    2.times { ready_suggestion }
    assert_enqueued_jobs 1, only: GiftIdeasJob do
      assert_difference("GiftSuggestion.count", 1) { press("gift_ideas:#{@list.id}") }
    end

    GiftSuggestion.where(user: @owner).delete_all
    GiftSuggestion.stubs(:global_daily_limit).returns(0)
    assert_no_enqueued_jobs only: GiftIdeasJob do
      assert_no_difference("GiftSuggestion.count") { press("gift_ideas:#{@list.id}") }
    end
    assert_includes text, @answer[:text]
    say("Manual gift")
    assert_equal "Manual gift", @list.items.sole.title
  end

  test "AI disabled after displaying the button redraws a complete manual prompt" do
    press("resume_input")
    GiftSuggestion.stubs(:enabled?).returns(false)
    assert_no_enqueued_jobs only: GiftIdeasJob do
      assert_no_difference("GiftSuggestion.count") { press("gift_ideas:#{@list.id}") }
    end
    refute_includes callbacks, "gift_ideas:#{@list.id}"
    assert_includes text, I18n.t("bot.gift_ideas.requests.disabled")
    say("Manual gift")
    assert_equal "Manual gift", @list.items.sole.title
  end

  test "failed results offer to resume manual input" do
    suggestion = ready_suggestion
    suggestion.fail!("no_ideas")
    press("show_gift_ideas:#{suggestion.id}")
    assert_includes text, I18n.t("bot.gift_ideas.failed.no_ideas")
    assert_includes callbacks, "resume_input"
    assert_includes callbacks, "cancel_input"
    press("resume_input")
    say("Manual gift")
    assert_equal "Manual gift", @list.items.sole.title
  end

  test "job failure sends a manual fallback without changing the pending input" do
    press("gift_ideas:#{@list.id}")
    suggestion = GiftSuggestion.order(:id).last
    before = @owner.reload.bot_payload
    ENV.stubs(:fetch).with("TELEGRAM_BOT_TOKEN").returns("local-test-token")
    Telegram::Bot::Client.stubs(:new).returns(stub(api: @api))
    generator = stub
    generator.stubs(:call).raises(YandexAi::Client::Error.new("timeout"))
    YandexAi::GiftIdeas.stubs(:new).returns(generator)

    GiftIdeasJob.perform_now(suggestion.id)

    assert suggestion.reload.failed?
    assert_equal before, @owner.reload.bot_payload
    assert_includes text, I18n.t("bot.gift_ideas.failed.technical")
    assert_includes callbacks, "resume_input"
  end

  private

  def ready_suggestion
    GiftSuggestion.create!(user: @owner, wishlist: @list).tap { |suggestion| suggestion.finish!([ "Lamp", "Book" ]) }
  end

  def callback_update(data)
    @update_id += 1
    Telegram::Bot::Types::Update.new(update_id: @update_id, callback_query: {
      id: @update_id.to_s, chat_instance: "chat", data: data,
      from: { id: @owner.telegram_id, is_bot: false, first_name: @owner.first_name },
      message: { message_id: 1, date: 1, chat: { id: @owner.telegram_id, type: "private" }, text: "Screen" }
    })
  end

  def press(data)
    dispatch(callback_update(data))
  end

  def say(value)
    @update_id += 1
    dispatch(Telegram::Bot::Types::Update.new(update_id: @update_id, message: {
      message_id: @update_id, date: 1, text: value,
      from: { id: @owner.telegram_id, is_bot: false, first_name: @owner.first_name },
      chat: { id: @owner.telegram_id, type: "private" }
    }))
  end

  def dispatch(update)
    Bot::Dispatcher.dispatch(@bot, update)
  end

  def text
    @screens.last.fetch(:text)
  end

  def buttons
    @screens.last[:reply_markup].inline_keyboard.flatten
  end

  def callbacks
    buttons.map(&:callback_data)
  end
end
