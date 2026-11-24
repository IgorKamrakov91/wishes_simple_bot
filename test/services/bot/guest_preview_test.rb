require "test_helper"
require "mocha/minitest"
require "telegram/bot"

Telegram::Bot::Types::Update

class BotGuestPreviewTest < ActiveSupport::TestCase
  setup do
    @owner = User.create!(telegram_id: 97801, first_name: "Owner")
    @guest = User.create!(telegram_id: 97802, first_name: "Secret Guest")
    @list = @owner.wishlists.create!(title: "Birthday")
    @screens = []
    @answers = []
    @api = stub
    @api.stubs(:send_message).with { |params| @screens << params; true }
    @api.stubs(:edit_message_text).with { |params| @screens << params; true }
    @api.stubs(:answer_callback_query).with { |params| @answers << params; true }
    @bot = stub(api: @api)
    @update_id = 9_780_100
  end

  test "the owner's list offers a preview only once it has gifts" do
    press(@owner, "open_list:#{@list.id}")
    refute_includes callbacks, "guest_preview:#{@list.id}"

    @list.items.create!(title: "Lamp")
    press(@owner, "open_list:#{@list.id}")
    assert_includes callbacks, "guest_preview:#{@list.id}"
  end

  test "the preview shows the guest view without actions or the reserver's name" do
    @list.items.create!(title: "Lamp", price: 2500)
    @list.items.create!(title: "Book", reserved_by: @guest.telegram_id)

    press(@owner, "guest_preview:#{@list.id}")

    assert_includes text, I18n.t("bot.screens.guest_preview.intro")
    assert_includes text, I18n.t("bot.screens.list.legend")
    refute_includes text, "Secret Guest"
    labels = buttons.map(&:text)
    assert_includes labels, "✓ Book"
    assert labels.any? { |label| label.start_with?("Lamp") }
    gift_callbacks = buttons.first(2).map(&:callback_data)
    assert_equal [ "preview_tap" ] * 2, gift_callbacks
    refute callbacks.compact.any? { |data| data.start_with?("open_item", "reserve_item", "add_item", "edit_item") }
    assert_equal Bot::Inline.share_query(@list), buttons.find(&:switch_inline_query_chosen_chat).switch_inline_query_chosen_chat.query
    assert_includes callbacks, "open_list:#{@list.id}"
  end

  test "the preview pages through long lists on its own route" do
    7.times { |i| @list.items.create!(title: "Gift #{i}") }
    press(@owner, "guest_preview:#{@list.id}")
    assert_includes callbacks, "guest_preview:#{@list.id}:1"
    refute callbacks.compact.any? { |data| data.start_with?("list_page") }

    press(@owner, "guest_preview:#{@list.id}:1")
    assert_includes text, I18n.t("bot.screens.guest_preview.intro")
    assert_includes callbacks, "guest_preview:#{@list.id}:0"
  end

  test "only the owner can preview a list" do
    @list.items.create!(title: "Lamp")
    @list.list_viewers.create!(user: @guest) # a guest with access still gets no preview
    assert_no_difference("@screens.size") { press(@guest, "guest_preview:#{@list.id}") }
    assert_equal I18n.t("bot.messages.not_available"), @answers.last[:text]
  end

  test "opening the preview and tapping a gift explain themselves and keep pending input" do
    @owner.update!(bot_state: "adding_item", bot_payload: { "wishlist_id" => @list.id })
    press(@owner, "guest_preview:#{@list.id}")
    assert_no_difference("@screens.size") { press(@owner, "preview_tap") }
    assert_equal I18n.t("bot.screens.guest_preview.tap"), @answers.last[:text]
    assert_equal "adding_item", @owner.reload.bot_state
  end

  test "the shared card invites without pressure and says the owner won't know" do
    @list.items.create!(title: "Lamp")
    card = Bot::Inline.inline_result_for_list(@list.reload).input_message_content.message_text
    assert_includes card, "Owner делится списком подарков «Birthday» — 1 подарок."
    assert_includes card, "Owner не узнает, кто что выбрал."
  end

  private

  def press(user, data)
    @update_id += 1
    Bot::Dispatcher.dispatch(@bot, Telegram::Bot::Types::Update.new(update_id: @update_id, callback_query: {
      id: @update_id.to_s, chat_instance: "chat", data: data,
      from: { id: user.telegram_id, is_bot: false, first_name: user.first_name },
      message: { message_id: 1, date: 1, chat: { id: user.telegram_id, type: "private" }, text: "Screen" }
    }))
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
