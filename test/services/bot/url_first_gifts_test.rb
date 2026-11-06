require "test_helper"
require "mocha/minitest"
require "telegram/bot"

Telegram::Bot::Types::Update

class BotUrlFirstGiftsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(telegram_id: 96001, first_name: "Owner")
    @wishlist = @user.wishlists.create!(title: "Birthday <&>")
    @api = mock("TelegramApi")
    @api.stubs(:answer_callback_query)
    @bot = stub(api: @api)
    @sent = []
    @api.stubs(:send_message).with { |params| @sent << params; true }
    @api.stubs(:edit_message_text).with { |params| @sent << params; true }
    @user.start_adding_item!(wishlist_id: @wishlist.id)
  end

  def build_message(text = nil, **extra)
    Telegram::Bot::Types::Message.new(
      message_id: 1, date: 1, **{ text: text }.compact, **extra,
      chat: { id: @user.telegram_id, type: "private" },
      from: { id: @user.telegram_id, is_bot: false, first_name: "Owner" }
    )
  end

  def say(text = nil, **extra)
    Bot::Commands.handle(@bot, build_message(text, **extra))
  end

  def press(data)
    Bot::Callbacks.handle(@bot, Telegram::Bot::Types::CallbackQuery.new(
      id: "draft", chat_instance: "chat", data: data,
      from: { id: @user.telegram_id, is_bot: false, first_name: "Owner" },
      message: { message_id: 1, date: 1, chat: { id: @user.telegram_id, type: "private" }, text: "Prompt" }
    ))
  end

  def buttons
    @sent.last[:reply_markup].inline_keyboard.flatten
  end

  test "a URL first stays unpublished until the gift has a valid name" do
    assert_no_difference("Item.count") { say("https://example.com/gift") }
    assert_equal "adding_item_title", @user.reload.bot_state
    assert_equal({ "wishlist_id" => @wishlist.id, "url" => "https://example.com/gift" }, @user.bot_payload)
    assert_includes @sent.last[:text], "Birthday &lt;&amp;&gt;"
    assert_equal [ "open_list:#{@wishlist.id}" ], buttons.map(&:callback_data)

    assert_difference("Item.count", 1) { say("Книга") }
    item = @wishlist.items.last
    assert_equal [ "Книга", "https://example.com/gift", nil, nil ], [ item.title, item.url, item.price, item.description ]
    assert_nil @user.reload.bot_state
    assert_nil @user.bot_payload
    assert_equal I18n.t("bot.messages.item_added"), screen_text(@sent.last[:text])
  end

  test "bare and Cyrillic-path links use the existing normalization and parser" do
    say("  ozon.ru/product/книга-123  ")
    assert_equal "https://ozon.ru/product/книга-123", @user.reload.bot_payload["url"]
    say("Книга")

    item = @wishlist.items.last
    assert_equal "https://ozon.ru/product/книга-123", item.url
    assert_equal "https://ozon.ru/product/%D0%BA%D0%BD%D0%B8%D0%B3%D0%B0-123", item.web_uri.to_s
  end

  test "dotted names at the first step remain names instead of becoming URLs" do
    [ "Lego.Technic", "Nike.Air" ].each do |title|
      @user.start_adding_item!(wishlist_id: @wishlist.id)
      assert_no_difference("Item.count") { say(title) }
      assert_equal "adding_item_url", @user.reload.bot_state
      assert_equal title, @user.bot_payload["title"]

      press("skip_item_url:#{@user.bot_payload['draft_id']}")
      assert_equal title, @wishlist.items.last.title
      assert_nil @wishlist.items.last.url
    end
  end

  test "dotted names after a URL finish the gift without changing that URL" do
    [ "Lego.Technic", "Nike.Air", "example.com/model" ].each do |title|
      @user.start_adding_item!(wishlist_id: @wishlist.id)
      say("https://example.com/gift")

      assert_difference("Item.count", 1) { say(title) }
      item = @wishlist.items.last
      assert_equal [ title, "https://example.com/gift" ], [ item.title, item.url ]
      assert_nil @user.reload.bot_state
    end
  end

  test "links longer than a title are accepted within the URL limit" do
    url = "https://example.com/#{'a' * 150}"
    say(url)
    assert_equal "adding_item_title", @user.reload.bot_state
    say("Подарок")
    assert_equal url, @wishlist.items.last.url
  end

  test "invalid explicit links stay at the first step and explain the URL error" do
    [ "https://", "https://bad_host.ru/item", "ftp://example.com/gift" ].each do |url|
      assert_no_difference("Item.count") { say(url) }
      assert_equal I18n.t("bot.input_errors.url.invalid"), @sent.last[:text]
      assert_equal "adding_item", @user.reload.bot_state
    end
  end

  test "the URL length limit is checked before staging a draft" do
    say("https://example.com/#{'a' * Item::URL_LIMIT}")

    assert_equal I18n.t("bot.input_errors.url.too_long", count: Item::URL_LIMIT), @sent.last[:text]
    assert_equal "adding_item", @user.reload.bot_state
    assert_equal({ "wishlist_id" => @wishlist.id }, @user.bot_payload)
  end

  test "invalid names keep the URL and allow correcting only the name" do
    say("https://example.com/gift")
    payload = @user.reload.bot_payload
    [ [ " ", "blank" ], [ "a" * 101, "too_long" ] ].each do |name, error|
      assert_no_difference("Item.count") { say(name) }
      assert_equal I18n.t("bot.input_errors.title.#{error}", count: Item::TITLE_LIMIT), @sent.last[:text]
      assert_equal "adding_item_title", @user.reload.bot_state
      assert_equal payload, @user.bot_payload
    end
    say("Плед")
    assert_equal "Плед", @wishlist.items.last.title
  end

  test "another link changes the draft URL and still asks for a name" do
    say("https://example.com/first")
    assert_no_difference("Item.count") { say("https://example.com/second") }
    assert_equal "adding_item_title", @user.reload.bot_state
    assert_equal "https://example.com/second", @user.bot_payload["url"]

    say("https://bad_host.ru")
    assert_equal "https://example.com/second", @user.reload.bot_payload["url"]
    say("Книга")
    assert_equal "https://example.com/second", @wishlist.items.last.url
  end

  test "cancel, start and the cancel button publish nothing" do
    [ "/cancel", "/start", :button ].each do |action|
      @user.start_adding_item!(wishlist_id: @wishlist.id)
      say("https://example.com/gift")
      assert_no_difference("Item.count") do
        action == :button ? press("open_list:#{@wishlist.id}") : say(action)
      end
      assert_nil @user.reload.bot_state
      assert_nil @user.bot_payload
    end
  end

  test "a photo is explained without losing the draft URL" do
    say("https://example.com/gift")
    say(photo: [ { file_id: "f", file_unique_id: "u", width: 1, height: 1 } ])

    assert_equal I18n.t("bot.input_errors.text_only"), @sent.last[:text]
    assert_equal "adding_item_title", @user.reload.bot_state
    assert_equal "https://example.com/gift", @user.bot_payload["url"]
    assert_equal [ "open_list:#{@wishlist.id}" ], buttons.map(&:callback_data)
  end

  test "a stale skip button cannot save or discard a URL-first draft" do
    say("https://example.com/gift")
    assert_no_difference("Item.count") { press("skip_item_url:dold") }
    assert_equal "adding_item_title", @user.reload.bot_state
    assert_equal "https://example.com/gift", @user.bot_payload["url"]
  end

  test "a list deleted during the name step clears the draft and explains why" do
    say("https://example.com/gift")
    @wishlist.destroy!
    assert_no_difference("Item.count") { say("Книга") }

    assert_equal I18n.t("bot.messages.input_target_gone"), @sent.last[:text]
    assert_nil @user.reload.bot_state
  end

  test "two handlers loaded with the same pending title save the gift once" do
    say("https://example.com/gift")
    contexts = 2.times.map do
      Bot::Context.new(bot: @bot, user: User.find(@user.id), source: build_message("Книга"))
    end

    assert_difference("Item.count", 1) { contexts.each { |context| Bot::StateHandler.new(context).handle } }
    assert_nil @user.reload.bot_state
  end

  test "price and description are optional actions after the gift is saved" do
    say("https://example.com/gift")
    say("Книга")
    item = @wishlist.items.last
    assert_includes buttons.map(&:callback_data), "edit_item_field:price:#{item.id}"
    assert_includes buttons.map(&:callback_data), "edit_item_field:description:#{item.id}"
    assert_includes buttons.map(&:callback_data), "open_item:#{item.id}"
    assert_nil @user.reload.bot_state

    press("edit_item_field:price:#{item.id}")
    say("1 500,50 ₽")
    assert_equal BigDecimal("1500.50"), item.reload.price
    press("edit_item_field:description:#{item.id}")
    say("Твёрдый переплёт")
    assert_equal "Твёрдый переплёт", item.reload.description
    assert_equal 1, @wishlist.items.count
  end

  test "title first and skip still save without forcing any details" do
    say("Плед")
    draft_id = @user.reload.bot_payload["draft_id"]
    press("skip_item_url:#{draft_id}")
    item = @wishlist.items.last

    assert_equal "Плед", item.title
    assert_nil item.url
    assert_nil @user.reload.bot_state
    assert_includes buttons.map(&:callback_data), "edit_item_field:price:#{item.id}"
    assert_includes buttons.map(&:callback_data), "edit_item_field:description:#{item.id}"
  end
end
