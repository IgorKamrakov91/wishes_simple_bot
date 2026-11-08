require "test_helper"
require "mocha/minitest"
require "telegram/bot"

Telegram::Bot::Types::Update

class BotGiftIdeasFlowTest < ActiveJob::TestCase
  class ProcessCrash < Exception; end

  setup do
    GiftSuggestion.stubs(:enabled?).returns(true)
    @owner = User.create!(telegram_id: 98201, first_name: "Owner")
    @guest = User.create!(telegram_id: 98202, first_name: "Guest")
    @wishlist = @owner.wishlists.create!(title: "Books & art")
    @wishlist.admit!(@guest)
    @api = mock("TelegramApi")
    @edits, @sent, @answers = [], [], []
    @api.stubs(:edit_message_text).with do |params|
      if @edit_error
        error, @edit_error = @edit_error, nil
        raise error
      end
      @edits << params
      true
    end
    @api.stubs(:send_message).with { |params| @sent << params; true }
    @api.stubs(:answer_callback_query).with do |params|
      if @answer_error
        error, @answer_error = @answer_error, nil
        raise error
      end
      @answers << params
      true
    end
    @bot = stub(api: @api)
    @update_id = 9_820_100
  end

  test "only owners see the entry and latest saved request, and disabled hides both" do
    suggestion = ready_suggestion
    press("open_list:#{@wishlist.id}")
    assert_includes callbacks, "gift_ideas:#{@wishlist.id}"
    assert_includes callbacks, "show_gift_ideas:#{suggestion.id}"

    press("open_list:#{@wishlist.id}", as: @guest)
    refute callbacks.any? { |data| data.to_s.match?(/gift_ideas/) }

    GiftSuggestion.stubs(:enabled?).returns(false)
    press("open_list:#{@wishlist.id}")
    refute callbacks.any? { |data| data.to_s.match?(/gift_ideas/) }
    assert_no_difference("GiftSuggestion.count") { press("gift_ideas:#{@wishlist.id}") }
    assert_equal I18n.t("bot.gift_ideas.requests.disabled"), @answers.last[:text]
  end

  test "requesting ideas keeps a draft and repeated clicks do not start a second job" do
    @owner.update!(bot_state: "adding_item_url", bot_payload: { "wishlist_id" => @wishlist.id, "title" => "Draft", "draft_id" => "d123" })
    payload = @owner.bot_payload

    assert_enqueued_jobs 1, only: GiftIdeasJob do
      assert_difference("GiftSuggestion.count", 1) { press("gift_ideas:#{@wishlist.id}") }
      press("gift_ideas:#{@wishlist.id}")
    end

    assert_equal payload, @owner.reload.bot_payload
    assert_equal "adding_item_url", @owner.bot_state
    assert_equal I18n.t("bot.gift_ideas.requests.active"), @answers.last[:text]
    assert_empty @edits
    assert_empty @sent
  end

  test "daily and global limits show actionable messages without jobs" do
    2.times { ready_suggestion }
    assert_no_enqueued_jobs only: GiftIdeasJob do
      press("gift_ideas:#{@wishlist.id}")
    end
    date = Time.current.in_time_zone(GiftSuggestion::TIME_ZONE).tomorrow.strftime("%d.%m")
    assert_equal [ I18n.t("bot.gift_ideas.requests.user_limit", date: date),
                   I18n.t("bot.gift_ideas.saved_hint", button: I18n.t("bot.gift_ideas.recent")) ].join(" "), @answers.last[:text]

    GiftSuggestion.where(user: @owner).delete_all
    GiftSuggestion.stubs(:global_daily_limit).returns(0)
    assert_no_enqueued_jobs only: GiftIdeasJob do
      press("gift_ideas:#{@wishlist.id}")
    end
    assert_equal I18n.t("bot.gift_ideas.requests.global_limit", date: date), @answers.last[:text]
  end

  test "adding an idea once shows marketplace search and keeps the other ideas reachable" do
    suggestion = ready_suggestion

    assert_difference("Item.count", 1) { press("add_idea:#{suggestion.id}:0") }

    item = @wishlist.items.sole
    assert_nil item.url
    assert_includes last_text, "Paint &amp; paper"
    assert_includes callbacks, "open_item:#{item.id}"
    assert_includes callbacks, "show_gift_ideas:#{suggestion.id}"
    assert_includes callbacks, "edit_item_field:url:#{item.id}"
    search_row = @edits.last[:reply_markup].inline_keyboard.first
    hosts = search_row.map { |button| URI.parse(button.url).host }
    assert_equal %w[market.yandex.ru www.ozon.ru www.wildberries.ru], hosts
    queries = search_row.map { |button| CGI.parse(URI.parse(button.url).query).values.flatten }
    assert_equal [ [ item.title ] ] * 3, queries

    assert_no_difference("Item.count") { press("add_idea:#{suggestion.id}:0") }
    assert_includes last_text, I18n.t("bot.gift_ideas.already_added", title: "Paint &amp; paper", list: "Books &amp; art")

    press("show_gift_ideas:#{suggestion.id}")
    assert_includes callbacks, "open_item:#{item.id}"
    assert_includes callbacks, "add_idea:#{suggestion.id}:1"
    refute_includes callbacks, "add_idea:#{suggestion.id}:0"
  end

  test "an unfinished input blocks adding and survives viewing saved ideas" do
    suggestion = ready_suggestion
    @owner.start_creating_list!

    assert_no_difference("Item.count") { press("add_idea:#{suggestion.id}:0") }
    assert_equal "creating_list", @owner.reload.bot_state
    assert_equal I18n.t("bot.gift_ideas.finish_input"), @answers.last[:text]
    assert_includes last_text, I18n.t("bot.messages.enter_list_name")

    press("show_gift_ideas:#{suggestion.id}")
    assert_equal "creating_list", @owner.reload.bot_state
    assert_includes last_text, I18n.t("bot.commands.input_active")
    assert_includes callbacks, "resume_input"
    assert_includes callbacks, "cancel_input"
  end

  test "the add-link button opens URL input for the saved idea and saves the reply" do
    suggestion = ready_suggestion
    press("add_idea:#{suggestion.id}:0")
    item = @wishlist.items.sole
    press("edit_item_field:url:#{item.id}")

    assert_equal "editing_item", @owner.reload.bot_state
    assert_equal "url", @owner.bot_payload["field"]
    assert_equal item.id, @owner.bot_payload["item_id"]
    assert_includes last_text, "Paint &amp; paper"

    @update_id += 1
    dispatch(Telegram::Bot::Types::Update.new(update_id: @update_id, message: {
      message_id: 101, date: 1, text: "https://market.yandex.ru/product/test",
      from: { id: @owner.telegram_id, is_bot: false, first_name: @owner.first_name },
      chat: { id: @owner.telegram_id, type: "private" }
    }))

    assert_equal "https://market.yandex.ru/product/test", item.reload.url
    assert_nil @owner.reload.bot_state
    assert_equal 1, @wishlist.items.count
  end

  test "a guest cannot request view or add the owner's ideas" do
    suggestion = ready_suggestion
    [ "gift_ideas:#{@wishlist.id}", "show_gift_ideas:#{suggestion.id}", "add_idea:#{suggestion.id}:0" ].each do |data|
      assert_no_difference([ "Item.count", "GiftSuggestion.count" ]) { press(data, as: @guest) }
      assert_equal I18n.t("bot.messages.not_available"), @answers.last[:text]
    end
    assert_empty @edits
    assert_empty @sent
  end

  test "deleted gifts and expired ideas are not recreated" do
    suggestion = ready_suggestion
    press("add_idea:#{suggestion.id}:0")
    @wishlist.items.sole.destroy!
    assert_no_difference("Item.count") { press("add_idea:#{suggestion.id}:0") }
    assert_equal I18n.t("bot.gift_ideas.add_results.gone"), @answers.last[:text]
    refute_includes last_text, "✓"
    assert_includes last_text, I18n.t("bot.gift_ideas.deleted_title", title: "Paint &amp; paper")
    refute callbacks.any? { |data| data.start_with?("open_item:") }
    refute_includes callbacks, "add_idea:#{suggestion.id}:0"
    assert_no_difference([ "Item.count", "GiftSuggestion.count" ]) { press("show_gift_ideas:#{suggestion.id}") }

    suggestion.update!(created_at: 3.days.ago)
    assert_no_difference("Item.count") { press("add_idea:#{suggestion.id}:1") }
    assert_includes last_text, I18n.t("bot.gift_ideas.expired")
    refute callbacks.any? { |data| data.to_s.start_with?("add_idea:") }
  end

  test "the latest request can be reopened after delivery fails without using another request" do
    suggestion = ready_suggestion
    GiftSuggestion.expects(:request_for!).never
    GiftIdeasJob.expects(:perform_later).never

    press("show_gift_ideas:#{suggestion.id}")

    assert_includes last_text, "Paint &amp; paper"
    assert_equal 1, GiftSuggestion.count
    suggestion.update!(status: "processing", started_at: 3.minutes.ago)
    press("show_gift_ideas:#{suggestion.id}")
    assert_includes last_text, I18n.t("bot.gift_ideas.failed.technical")
  end

  test "saved ideas select the latest ready unexpired set for this owner and list" do
    ready_suggestion.update!(created_at: 2.days.ago - 1.second)
    press("open_list:#{@wishlist.id}")
    refute callbacks.any? { |data| data.start_with?("show_gift_ideas:") }

    ready_suggestion
    latest = ready_suggestion
    GiftSuggestion.create!(user: @owner, wishlist: @wishlist, status: "failed", error_code: "no_ideas")
    GiftSuggestion.create!(user: @owner, wishlist: @wishlist, status: "pending")
    GiftSuggestion.create!(user: @owner, wishlist: @owner.wishlists.create!(title: "Other"), status: "ready")
    GiftSuggestion.create!(user: @guest, wishlist: @wishlist, status: "ready")

    press("open_list:#{@wishlist.id}")
    assert_equal [ "show_gift_ideas:#{latest.id}" ], callbacks.grep(/show_gift_ideas:/)
    assert_no_enqueued_jobs only: GiftIdeasJob do
      assert_no_difference("GiftSuggestion.count") { press("show_gift_ideas:#{latest.id}") }
    end
    assert_includes last_text, "Paint &amp; paper"
  end

  test "remaining quota is personal across lists excludes failures and resets at Moscow midnight" do
    travel_to Time.utc(2026, 11, 9, 20, 59) do
      other = @owner.wishlists.create!(title: "Other")
      GiftSuggestion.create!(user: @guest, wishlist: @guest.wishlists.create!(title: "Guest"), status: "ready")
      press("open_list:#{@wishlist.id}")
      assert_equal "💡 Идеи подарков (осталось 2)", idea_button.text

      GiftSuggestion.create!(user: @owner, wishlist: other, status: "failed")
      press("open_list:#{@wishlist.id}")
      assert_equal "💡 Идеи подарков (осталось 2)", idea_button.text
      ready_suggestion
      press("open_list:#{@wishlist.id}")
      assert_equal "💡 Идеи подарков (осталось 1)", idea_button.text
      GiftSuggestion.create!(user: @owner, wishlist: other, status: "ready")
      press("open_list:#{@wishlist.id}")
      assert_equal "💡 Идеи подарков (осталось 0)", idea_button.text
      assert_no_enqueued_jobs only: GiftIdeasJob do
        assert_no_difference("GiftSuggestion.count") { press("gift_ideas:#{@wishlist.id}") }
      end
      assert_includes @answers.last[:text], "10.11 в 00:00 МСК"
      assert_includes @answers.last[:text], I18n.t("bot.gift_ideas.saved_hint", button: I18n.t("bot.gift_ideas.recent"))
      assert_operator @answers.last[:text].length, :<=, 200
    end
    travel_to Time.utc(2026, 11, 9, 21, 0) do
      press("open_list:#{@wishlist.id}")
      assert_equal "💡 Идеи подарков (осталось 2)", idea_button.text
    end
  end

  test "a failed request restores two remaining and can be retried in both locales" do
    %i[ru en].each do |locale|
      I18n.with_locale(locale) do
        assert_enqueued_jobs 1, only: GiftIdeasJob do
          press("gift_ideas:#{@wishlist.id}")
        end
        suggestion = GiftSuggestion.order(:id).last
        press("open_list:#{@wishlist.id}")
        assert_equal locale == :ru ? "💡 Идеи подарков (осталось 1)" : "💡 Gift ideas (1 left)", idea_button.text

        suggestion.fail!("no_ideas")
        press("show_gift_ideas:#{suggestion.id}")
        assert_includes last_text, locale == :ru ? "попытка не засчитана" : "attempt wasn't counted"
        press("open_list:#{@wishlist.id}")
        assert_equal locale == :ru ? "💡 Идеи подарков (осталось 2)" : "💡 Gift ideas (2 left)", idea_button.text
      end
    end
  end

  test "English global limit points to saved ideas only when this list has a ready set" do
    ready_suggestion
    GiftSuggestion.stubs(:global_daily_limit).returns(0)
    I18n.with_locale(:en) do
      press("open_list:#{@wishlist.id}")
      assert_equal "💡 Gift ideas (1 left)", idea_button.text
      press("gift_ideas:#{@wishlist.id}")
      assert_includes @answers.last[:text], "00:00 Moscow time"
      hint = I18n.t("bot.gift_ideas.saved_hint", button: I18n.t("bot.gift_ideas.recent"))
      assert_includes @answers.last[:text], hint
      assert_operator @answers.last[:text].length, :<=, 200

      other = @owner.wishlists.create!(title: "Other")
      press("gift_ideas:#{other.id}")
      refute_includes @answers.last[:text], hint
    end
  end

  test "retry after a committed request does not spend quota again" do
    @answer_error = ProcessCrash.new
    update = callback_update("gift_ideas:#{@wishlist.id}")
    assert_raises(ProcessCrash) { dispatch(update) }
    receipt = BotUpdateReceipt.find(update.update_id)
    assert_equal "gift_ideas", receipt.result_kind
    assert_nil receipt.delivered_at
    assert_equal 1, GiftSuggestion.count
    GiftSuggestion.expects(:request_for!).never

    assert_no_difference("GiftSuggestion.count") { dispatch(update) }

    assert_includes last_text, I18n.t("bot.gift_ideas.waiting")
    assert receipt.reload.delivered_at
  end

  test "a committed add recovers the search buttons after a Telegram timeout" do
    suggestion = ready_suggestion
    update = callback_update("add_idea:#{suggestion.id}:0")
    @edit_error = Faraday::TimeoutError.new

    assert_difference("Item.count", 1) { dispatch(update) }

    receipt = BotUpdateReceipt.find(update.update_id)
    assert_equal "gift_idea_added", receipt.result_kind
    assert_nil receipt.delivered_at
    assert_includes @answers.last[:text], I18n.t("bot.messages.update_results.gift_idea_added")
    assert_no_difference("Item.count") { dispatch(update) }
    assert receipt.reload.delivered_at
    assert_equal 3, @edits.last[:reply_markup].inline_keyboard.first.count(&:url)
    assert_includes callbacks, "edit_item_field:url:#{@wishlist.items.sole.id}"
  end

  test "recovering a deleted AI gift does not expose old titles or create another gift" do
    suggestion = ready_suggestion
    update = callback_update("add_idea:#{suggestion.id}:0")
    @edit_error = Faraday::TimeoutError.new
    dispatch(update)
    @wishlist.items.sole.destroy!

    assert_no_difference("Item.count") { dispatch(update) }

    assert_includes @sent.last[:text], I18n.t("bot.messages.result_unavailable")
    refute_includes @sent.last[:text], "Paint"
  end

  test "help explains data sharing and the two daily requests in both locales" do
    %i[ru en].each do |locale|
      I18n.with_locale(locale) do
        press("help")
        assert_includes last_text, "Yandex AI"
        assert_includes last_text, locale == :ru ? "два подбора в сутки по Москве" : "two sets of ideas per day"
        assert_includes last_text, locale == :ru ? "Неудачные попытки не расходуют личный лимит" : "Failed attempts don't use your personal limit"
      end
    end
  end

  private

  def ready_suggestion
    GiftSuggestion.create!(user: @owner, wishlist: @wishlist).tap do |suggestion|
      suggestion.finish!([ "Paint & paper", "Lamp" ])
    end
  end

  def callback_update(data, as: @owner)
    @update_id += 1
    Telegram::Bot::Types::Update.new(update_id: @update_id, callback_query: {
      id: "ideas", chat_instance: "chat", data: data,
      from: { id: as.telegram_id, is_bot: false, first_name: as.first_name },
      message: { message_id: 8, date: 1, chat: { id: as.telegram_id, type: "private" }, text: "Screen" }
    })
  end

  def press(data, as: @owner)
    dispatch(callback_update(data, as: as))
  end

  def dispatch(update)
    Bot::Dispatcher.dispatch(@bot, update)
  end

  def last_text
    (@edits.last || @sent.last).fetch(:text)
  end

  def callbacks
    @edits.last[:reply_markup].inline_keyboard.flatten.map(&:callback_data).compact
  end

  def idea_button
    @edits.last[:reply_markup].inline_keyboard.flatten.find { |button| button.callback_data == "gift_ideas:#{@wishlist.id}" }
  end
end
