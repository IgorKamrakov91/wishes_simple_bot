require "test_helper"
require "mocha/minitest"
require "telegram/bot"

Telegram::Bot::Types::Update

class BotInputFlowContextTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(telegram_id: 99401, first_name: "Input")
    @wishlist = @user.wishlists.create!(title: "Birthday <&>")
    @api = mock("TelegramApi")
    @api.stubs(:answer_callback_query)
    @bot = stub(api: @api)
    @screens = []
    @api.stubs(:send_message).with { |params| @screens << params; true }
    @api.stubs(:edit_message_text).with { |params| @screens << params; true }
    @message_id = 100
  end

  test "URL errors and non-text replies keep the same save-without-link action" do
    press("add_item:#{@wishlist.id}")
    say("Puzzle <&>")
    draft = @user.reload.bot_payload
    skip = "skip_item_url:#{draft['draft_id']}"

    say("not a URL")
    assert_equal [ skip, "open_list:#{@wishlist.id}" ], callbacks
    assert_equal draft, @user.reload.bot_payload
    assert_includes screen[:text], I18n.t("bot.input_errors.url.invalid")

    say(nil, sticker: { file_id: "s", file_unique_id: "u", type: "regular", width: 1, height: 1, is_animated: false, is_video: false })
    assert_equal [ skip, "open_list:#{@wishlist.id}" ], callbacks
    assert_equal draft, @user.reload.bot_payload

    assert_difference("Item.count", 1) { press(skip) }
    assert_equal "Puzzle <&>", @wishlist.items.last.title
    assert_nil @wishlist.items.last.url
    assert_includes screen[:text], "Puzzle &lt;&amp;&gt;"
    assert_includes screen[:text], "Birthday &lt;&amp;&gt;"
  end

  test "an invalid edit retains the named clear action for every optional field" do
    item = @wishlist.items.create!(title: "Puzzle", price: 10, url: "https://shop.example/puzzle", description: "Details")
    { "price" => [ "invalid", "Убрать цену" ], "url" => [ "invalid", "Убрать ссылку" ],
      "description" => [ "x" * (Item::DESCRIPTION_LIMIT + 1), "Убрать описание" ] }.each do |field, (value, label)|
      press("edit_item_field:#{field}:#{item.id}")
      say(value)

      clear = buttons.find { |button| button.callback_data == "clear_item_field:#{field}:#{item.id}" }
      assert_equal label, clear&.text
      assert_equal "editing_item", @user.reload.bot_state
      assert_includes callbacks, "open_item:#{item.id}"
      press(clear.callback_data)
      assert_nil item.reload.public_send(field)
      assert_nil @user.reload.bot_state
    end
  end

  test "resumed editing and renaming prompts identify the escaped gift and list" do
    item = @wishlist.items.create!(title: "Puzzle <&>", price: 10)
    press("edit_item_field:price:#{item.id}")
    say("/help")
    press("resume_input")

    assert_includes screen[:text], "Puzzle &lt;&amp;&gt;"
    assert_includes screen[:text], "Birthday &lt;&amp;&gt;"
    assert_includes screen[:text], I18n.t("bot.fields.price")
    press("rename_list:#{@wishlist.id}")
    assert_includes screen[:text], "Birthday &lt;&amp;&gt;"
    assert_includes screen[:text], I18n.t("bot.messages.enter_new_list_name")
  end

  test "a new list immediately asks for its first gift and Later keeps the list" do
    say("/new")
    say("Travel <&>")
    list = @user.wishlists.order(:id).last

    assert_equal "adding_item", @user.reload.bot_state
    assert_includes screen[:text], "Travel &lt;&amp;&gt;"
    assert_includes screen[:text], "первого подарка"
    assert_equal [ "open_list:#{list.id}" ], callbacks
    assert_equal "Позже", buttons.first.text
    assert_empty list.items

    assert_no_difference("Wishlist.count") { press(buttons.first.callback_data) }
    assert_nil @user.reload.bot_state
    assert_includes screen[:text], "Travel &lt;&amp;&gt;"
    assert_empty list.items
  end

  test "cancel exits the first-gift prompt without deleting the new list" do
    say("/new")
    say("Travel")

    assert_no_difference("Wishlist.count") { say("/cancel") }

    assert @user.wishlists.exists?(title: "Travel")
    assert_nil @user.reload.bot_state
  end

  test "opening an existing empty list does not start input" do
    press("open_list:#{@wishlist.id}")

    assert_nil @user.reload.bot_state
    assert_includes callbacks, "add_item:#{@wishlist.id}"
  end

  test "a fresh handler ignores the list-name message after the state advances" do
    say("/new")
    name = build_message("Travel")
    Bot::Commands.handle(@bot, name)
    list = @user.wishlists.order(:id).last
    checkpoint = @user.reload.last_list_creation_message_id
    before = @user.attributes.slice("bot_state", "bot_payload")

    assert_no_difference("Wishlist.count") { Bot::Commands.handle(@bot, name) }
    assert_equal name.message_id, checkpoint
    assert_equal before, @user.reload.attributes.slice("bot_state", "bot_payload")
    assert_empty list.items

    say("Puzzle")
    draft = @user.reload.bot_payload
    Bot::Commands.handle(@bot, name)
    assert_equal draft, @user.reload.bot_payload
    assert_empty list.items
  end

  test "a late list-name message cannot enter a later draft or edit" do
    say("/new")
    name = build_message("Travel")
    Bot::Commands.handle(@bot, name)
    say("/cancel")
    press("add_item:#{@wishlist.id}")

    Bot::Commands.handle(@bot, name)
    assert_equal({ "wishlist_id" => @wishlist.id }, @user.reload.bot_payload)

    item = @wishlist.items.create!(title: "Puzzle", description: "Original")
    press("edit_item_field:description:#{item.id}")
    Bot::Commands.handle(@bot, name)
    assert_equal "Original", item.reload.description
    assert_equal "editing_item", @user.reload.bot_state
  end

  test "the first gift may legitimately have the same text as the list name" do
    say("/new")
    name = build_message("Travel")
    Bot::Commands.handle(@bot, name)
    list = @user.wishlists.order(:id).last
    say("Travel")
    draft = @user.reload.bot_payload

    assert_difference("Item.count", 1) { press("skip_item_url:#{draft['draft_id']}") }

    assert_equal "Travel", list.items.sole.title
  end

  test "two preloaded handlers of the list-name message create one list and no gift draft" do
    @user.start_creating_list!
    name = build_message("Travel")
    contexts = 2.times.map { Bot::Context.new(bot: @bot, user: User.find(@user.id), source: name) }

    assert_difference("Wishlist.count", 1) do
      assert_no_difference("Item.count") { contexts.each { |context| Bot::StateHandler.new(context).handle } }
    end

    assert_equal "adding_item", @user.reload.bot_state
    refute @user.bot_payload.key?("title")
    assert @user.bot_payload["first_item"]
  end

  test "the price limit error names the strict model boundary and accepts a smaller amount" do
    item = @wishlist.items.create!(title: "Puzzle")
    press("edit_item_field:price:#{item.id}")
    say(Item::PRICE_LIMIT.to_s)

    limit = Object.new.extend(Bot::Helpers).format_price(Item::PRICE_LIMIT)
    assert_includes screen[:text], limit
    assert_includes screen[:text], "меньше"
    assert_nil item.reload.price
    assert_equal "editing_item", @user.reload.bot_state

    say((Item::PRICE_LIMIT - 1).to_s)
    assert_equal (Item::PRICE_LIMIT - 1).to_d, item.reload.price
  end

  private

  def screen
    @screens.last
  end

  def buttons
    screen[:reply_markup].inline_keyboard.flatten
  end

  def callbacks
    buttons.map(&:callback_data)
  end

  def build_message(text, **extra)
    @message_id += 1
    Telegram::Bot::Types::Message.new(
      message_id: @message_id, date: 1, **{ text: text }.compact, **extra,
      chat: { id: @user.telegram_id, type: "private" },
      from: { id: @user.telegram_id, is_bot: false, first_name: @user.first_name }
    )
  end

  def say(text, **extra)
    Bot::Commands.handle(@bot, build_message(text, **extra))
  end

  def press(data)
    Bot::Callbacks.handle(@bot, Telegram::Bot::Types::CallbackQuery.new(
      id: "input", chat_instance: "chat", data: data,
      from: { id: @user.telegram_id, is_bot: false, first_name: @user.first_name },
      message: { message_id: 7, date: 1, chat: { id: @user.telegram_id, type: "private" }, text: "Screen" }
    ))
  end
end
