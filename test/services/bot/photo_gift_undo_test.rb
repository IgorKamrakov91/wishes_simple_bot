require "test_helper"
require "mocha/minitest"
require "telegram/bot"

Telegram::Bot::Types::Update

class BotPhotoGiftUndoTest < ActiveSupport::TestCase
  setup do
    @flag = ENV["PHOTO_GIFTS_ENABLED"]
    ENV["PHOTO_GIFTS_ENABLED"] = "true"
    @owner = User.create!(telegram_id: 97_501, first_name: "Owner")
    @other = User.create!(telegram_id: 97_502, first_name: "Other")
    @list = @owner.wishlists.create!(title: "Birthday")
    @item = @list.items.create!(title: "Лампа", photo_file_id: "p")
    @draft = PhotoGiftDraft.create!(user: @owner, wishlist: @list, item: @item, status: "saved", chat_id: 1,
      message_id: 1, file_id: "f", media_kind: "photo", media_status: "ready", locale: "ru", expires_at: 1.day.from_now)
    @screens = []
    @answers = []
    @api = stub
    @api.stubs(:edit_message_text).with { |params| @screens << params; true }
    @api.stubs(:send_message).with { |params| @screens << params; true }
    @api.stubs(:answer_callback_query).with { |params| @answers << params; true }
    @bot = stub(api: @api)
    @id = 9_750_000
  end

  teardown { ENV["PHOTO_GIFTS_ENABLED"] = @flag }

  test "undo removes the gift saved on its own, once" do
    assert_difference("Item.count", -1) { press("pgu:#{@draft.id}") }
    assert_includes @screens.last[:text], I18n.t("bot.photo_gift.undone")
    assert_no_difference("Item.count") { press("pgu:#{@draft.id}") }
  end

  test "a reserved gift is not removed from under the guest" do
    @item.update!(reserved_by: @other.telegram_id)
    assert_no_difference("Item.count") { press("pgu:#{@draft.id}") }
    assert_equal I18n.t("bot.photo_gift.undo_reserved"), @answers.last[:text]
  end

  test "nobody else can undo it" do
    assert_no_difference("Item.count") { press("pgu:#{@draft.id}", as: @other) }
  end

  private

  def press(data, as: @owner)
    @id += 1
    Bot::Dispatcher.dispatch(@bot, Telegram::Bot::Types::Update.new(update_id: @id, callback_query: {
      id: @id.to_s, chat_instance: "chat", data: data,
      from: { id: as.telegram_id, is_bot: false, first_name: as.first_name },
      message: { message_id: 1, date: 1, chat: { id: as.telegram_id, type: "private" }, text: "Screen" }
    }))
  end
end
