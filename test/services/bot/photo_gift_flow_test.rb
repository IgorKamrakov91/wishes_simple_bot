require "test_helper"
require "mocha/minitest"
require "telegram/bot"

Telegram::Bot::Types::Update

class BotPhotoGiftFlowTest < ActiveJob::TestCase
  setup do
    @flag = ENV["PHOTO_GIFTS_ENABLED"]
    ENV["PHOTO_GIFTS_ENABLED"] = "true"
    @owner = User.create!(telegram_id: 97911, first_name: "Owner")
    @guest = User.create!(telegram_id: 97912, first_name: "Guest")
    @list = @owner.wishlists.create!(title: "Birthday")
    @screens, @answers, @photos = [], [], []
    @api = stub
    @api.stubs(:send_message).with { |params| @screens << params; true }
    @api.stubs(:edit_message_text).with { |params| @screens << params; true }
    @api.stubs(:send_photo).with { |params| @photos << params; true }
    @api.stubs(:answer_callback_query).with { |params| @answers << params; true }
    @bot = stub(api: @api)
    @id = 9_791_000
    Telegram::Bot::Client.expects(:new).never
  end

  teardown do
    ENV["PHOTO_GIFTS_ENABLED"] = @flag
  end

  test "flag off preserves caption input and text-only feedback" do
    ENV.delete("PHOTO_GIFTS_ENABLED")
    @owner.start_adding_item!(wishlist_id: @list.id)
    assert_difference("Item.count", 1) { photo(caption: "Lamp") }
    assert_equal "Lamp", @list.items.last.title
    assert_empty PhotoGiftDraft.all
    photo
    assert_includes text, I18n.t("bot.commands.text_only")
  end

  test "first photo asks consent and manual review saves a first gift only once" do
    assert_no_difference("Item.count") { photo }
    draft = latest
    assert_includes text, I18n.t("bot.photo_gift.consent")
    press("m", draft)
    assert_nil @owner.reload.photo_ai_consented_at
    assert_includes text, I18n.t("bot.photo_gift.review")
    press("s", draft)
    assert_equal "editing_photo_gift", @owner.reload.bot_state
    say(text: "Lamp")
    assert_equal "photo_gift", @owner.reload.bot_state
    press("p", draft)
    say(text: "2 500,50 ₽")
    assert_equal "2500.50", latest.result["price"]
    press("d", draft)
    say(text: "Size 43 <check>")
    press("u", draft)
    say(text: "example.com/gift")
    assert_includes text, "Size 43 &lt;check&gt;"
    assert_includes text, I18n.t("bot.photo_gift.photo_public")
    callback = "pg:s:#{draft.id}:#{draft.reload.version}"
    assert_difference("Item.count", 1) { press_data(callback) }
    assert_includes text, "первый подарок"
    assert_equal "photo-large", latest.item.photo_file_id
    assert_equal BigDecimal("2500.50"), latest.item.price
    assert_no_difference("Item.count") { press_data(callback) }
  end

  test "consent goes pending without a recognition job and later photos skip consent" do
    photo(caption: "My caption")
    draft = latest
    assert_no_enqueued_jobs { press("a", draft) }
    assert_equal "pending", draft.reload.status
    assert @owner.reload.photo_ai_consented_at
    assert_includes text, "My caption"
    photo(caption: "https://example.com/gift")
    assert_equal "pending", latest.status
    assert_equal "https://example.com/gift", latest.result["url"]
    assert_equal "cancelled", draft.reload.status
  end

  test "a newcomer's draft can resume from start and menu even without a list" do
    @list.destroy!
    photo(caption: "Lamp")
    draft = latest
    press("m", draft)
    say(text: "/start")
    assert_equal "photo_gift", @owner.reload.bot_state
    assert_includes callbacks, "resume_input"
    press_data("main_menu")
    assert_equal "ready", draft.reload.status
    press_data("resume_input")
    assert_includes text, I18n.t("bot.photo_gift.review")
  end

  test "a committed save with a failed reply recovers without repeating creation" do
    photo(caption: "Gift")
    draft = latest
    press("m", draft)
    data = "pg:s:#{draft.id}:#{draft.reload.version}"
    @api.stubs(:edit_message_text).raises(Faraday::TimeoutError)
    @id += 1
    @saved_update = @id
    dispatch_press(data, @owner, @saved_update)
    assert_equal 1, Item.where(wishlist: @list).count
    @api.stubs(:edit_message_text).with { |params| @screens << params; true }
    dispatch_press(data, @owner, @saved_update)
    assert_equal 1, Item.where(wishlist: @list).count
    assert_includes text, "первый подарок"
  end

  test "photo uses only the adding list or latest own list and creates none until save" do
    another = @owner.wishlists.create!(title: "Other")
    @owner.start_adding_item!(wishlist_id: @list.id)
    photo
    assert_equal @list.id, latest.wishlist_id
    press("c", latest)
    photo
    assert_equal another.id, latest.wishlist_id
    @owner.clear_state!
    @owner.wishlists.destroy_all
    assert_no_difference("Wishlist.count") { photo(caption: "Book") }
    press("m", latest)
    assert_difference("Wishlist.count", 1) { press("s", latest) }
    assert_equal "Мои желания", latest.wishlist.title
  end

  test "list picker paginates validates ownership and supports a new list" do
    7.times { |i| @owner.wishlists.create!(title: "List #{i}") }
    photo(caption: "Book")
    press("m", latest)
    press("l", latest)
    assert callbacks.any? { |data| data.start_with?("pgl:") }
    page = callbacks.find { |data| data.start_with?("pgl:") }
    press_data(page)
    assert_includes text, I18n.t("bot.photo_gift.choose_list")
    draft = latest
    foreign = @guest.wishlists.create!(title: "Foreign")
    press_data("pgw:#{draft.id}:#{draft.version}:#{foreign.id}")
    refute_equal foreign.id, draft.reload.wishlist_id
    press_data("pgw:#{draft.id}:#{draft.version}:0")
    assert draft.reload.result["new_list"]
    press("s", draft)
    assert_equal "Мои желания", draft.reload.wishlist.title
  end

  test "existing title url and editing states keep caption semantics without a photo draft" do
    states = {
      "adding_item_title" => { "wishlist_id" => @list.id, "url" => "https://example.com" },
      "adding_item_url" => { "wishlist_id" => @list.id, "title" => "Existing", "draft_id" => "d1" }
    }
    states.each do |state, payload|
      @owner.update!(bot_state: state, bot_payload: payload)
      assert_no_difference("PhotoGiftDraft.count") { photo }
      assert_equal state, @owner.reload.bot_state
    end
    photo(caption: "https://example.com/other")
    assert_empty PhotoGiftDraft.all
    assert_equal "Existing", @list.items.last.title
    @owner.start_creating_list!
    assert_difference("Wishlist.count", 1) { photo(caption: "Caption list") }
    assert_empty PhotoGiftDraft.all
  end

  test "a command in a photo caption cancels input without intake" do
    photo
    draft = latest
    photo(caption: "/cancel")
    assert_nil @owner.reload.bot_state
    assert_equal "cancelled", draft.reload.status
    assert_equal 1, PhotoGiftDraft.count
  end

  test "new photo cancels old draft and album photos produce only one hint" do
    photo(media_group_id: "album")
    first = latest
    2.times { photo(media_group_id: "album") }
    assert_equal 1, PhotoGiftDraft.count
    assert_equal 1, @screens.count { |screen| screen[:text].include?(I18n.t("bot.photo_gift.one_photo")) }
    photo
    assert_equal "cancelled", first.reload.status
    press("m", first)
    assert_includes text, I18n.t("bot.photo_gift.unavailable")
  end

  test "no guest or group can create a gift in the owner's list or access a private draft" do
    @list.admit!(@guest)
    photo
    draft = latest
    before = draft.attributes
    press_data("pg:a:#{draft.id}:#{draft.version}", as: @guest)
    assert_equal before, draft.reload.attributes
    assert_nil @guest.reload.photo_ai_consented_at
    press_data("open_list:#{@list.id}", as: @guest)
    photo(as: @guest)
    assert_nil @guest.photo_gift_drafts.last.wishlist_id
    assert_no_difference("PhotoGiftDraft.count") { photo(chat_type: "group") }
  end

  test "photo controls are access checked and do not clear pending input" do
    item = @list.items.create!(title: "Lamp", photo_file_id: "safe-photo")
    press_data("open_item:#{item.id}")
    assert_includes callbacks, "ip:#{item.id}"
    @owner.start_creating_list!
    press_data("ip:#{item.id}")
    assert_equal [ { chat_id: @owner.telegram_id, photo: "safe-photo" } ], @photos
    assert_equal "creating_list", @owner.reload.bot_state
    assert_no_difference("@photos.size") { press_data("ip:#{item.id}", as: @guest) }
    @list.admit!(@guest)
    press_data("ip:#{item.id}", as: @guest)
    assert_equal @guest.telegram_id, @photos.last[:chat_id]
    @list.list_viewers.delete_all
    assert_no_difference("@photos.size") { press_data("ip:#{item.id}", as: @guest) }
  end

  test "removing a photo saving text and back from editing never publishes early" do
    photo(caption: "Gift")
    draft = latest
    press("m", draft)
    press("t", draft)
    assert_no_difference("Item.count") { press_data("pgb:#{draft.id}") }
    press("x", draft)
    refute_includes text, I18n.t("bot.photo_gift.photo_public")
    press("s", draft)
    assert_nil draft.reload.item.photo_file_id
  end

  test "invalid fields keep the edit open and stale buttons cannot overwrite fields" do
    photo
    draft = latest
    press("m", draft)
    version = draft.reload.version
    press("p", draft)
    say(text: "not a price")
    assert_equal "editing_photo_gift", @owner.reload.bot_state
    say(text: "500")
    press_data("pg:x:#{draft.id}:#{version}")
    refute draft.reload.result["without_photo"]
    assert_equal "500", draft.result["price"]
  end

  test "a valid image document is queued for preparation without recognizing it" do
    assert_enqueued_with(job: PhotoGiftDocumentJob) do
      say(document: { file_id: "document", file_unique_id: "unique", mime_type: "image/png", file_size: 100 })
    end
    assert_equal "document", latest.media_kind
    assert_equal "pending", latest.media_status
    assert_nil latest.photo_file_id
    assert_includes text, I18n.t("bot.photo_gift.consent")
    count = PhotoGiftDraft.count
    press("c", latest)
    say(document: { file_id: "bad", file_unique_id: "other", mime_type: "application/pdf" })
    assert_equal count, PhotoGiftDraft.count
    assert_includes text, I18n.t("bot.photo_gift.unsupported")
  end

  test "webhook reply recovery reopens the draft and does not create it twice" do
    @api.stubs(:send_message).raises(Faraday::TimeoutError)
    photo(update_id: 9_799_000)
    assert_equal 1, PhotoGiftDraft.count
    @api.stubs(:send_message).with { |params| @screens << params; true }
    photo(update_id: 9_799_000)
    assert_equal 1, PhotoGiftDraft.count
    assert_includes text, I18n.t("bot.photo_gift.consent")
    assert BotUpdateReceipt.find(9_799_000).delivered_at
  end

  test "both locales render escaped fields and callbacks stay below Telegram's limit" do
    %i[ru en].each do |locale|
      I18n.with_locale(locale) do
        photo(caption: "<Lamp>")
        press("m", latest)
        assert_includes text, "&lt;Lamp&gt;"
        refute_includes text, "Translation missing"
        assert callbacks.all? { |data| data.bytesize < 64 }
      end
    end
    huge = 9_223_372_036_854_775_807
    assert_operator "pgw:#{huge}:2147483647:#{huge}".bytesize, :<, 64
  end

  private

  def latest
    @owner.photo_gift_drafts.order(:id).last
  end

  def photo(**attributes)
    say(photo: [ { file_id: "photo-small", file_unique_id: "small", width: 100, height: 100 },
                 { file_id: "photo-large", file_unique_id: "large", width: 2048, height: 1200 } ], **attributes)
  end

  def say(as: @owner, chat_type: "private", update_id: nil, **attributes)
    @id += 1
    Bot::Dispatcher.dispatch(@bot, Telegram::Bot::Types::Update.new(update_id: update_id || @id, message: {
      message_id: @id, date: 1, chat: { id: as.telegram_id, type: chat_type },
      from: { id: as.telegram_id, is_bot: false, first_name: as.first_name }, **attributes
    }))
  end

  def press(action, draft)
    press_data("pg:#{action}:#{draft.id}:#{draft.reload.version}")
  end

  def press_data(data, as: @owner)
    @id += 1
    dispatch_press(data, as, @id)
  end

  def dispatch_press(data, as, update_id)
    Bot::Dispatcher.dispatch(@bot, Telegram::Bot::Types::Update.new(update_id: update_id, callback_query: {
      id: update_id.to_s, chat_instance: "chat", data: data,
      from: { id: as.telegram_id, is_bot: false, first_name: as.first_name },
      message: { message_id: 1, date: 1, chat: { id: as.telegram_id, type: "private" }, text: "Screen" }
    }))
  end

  def text
    @screens.last.fetch(:text)
  end

  def callbacks
    @screens.last[:reply_markup].inline_keyboard.flatten.filter_map(&:callback_data)
  end
end
