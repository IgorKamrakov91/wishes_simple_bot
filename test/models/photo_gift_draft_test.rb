require "test_helper"
require "mocha/minitest"

class PhotoGiftDraftTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(telegram_id: 97901)
    @list = @user.wishlists.create!(title: "Birthday")
    @counter = 0
  end

  test "caption fields remain private until explicitly saved and consent is persistent" do
    assert_no_difference("Item.count") { @draft = start(caption: "Lamp") }
    assert_equal "awaiting_consent", @draft.status
    assert_nil @user.first_item_at
    assert @draft.consent!(expected_version: 0)
    assert @user.reload.photo_ai_consented_at
    assert_equal "pending", @draft.status
    assert start.status == "pending"
  end

  test "manual input does not consent and versions invalidate recognition" do
    draft = start
    assert draft.manual!(expected_version: 0)
    refute draft.apply_recognition!(title: "AI", price: 100, description: nil, expected_version: 0)
    assert_nil @user.reload.photo_ai_consented_at
    assert draft.update_field!("title", "Human", expected_version: 1)
    assert_equal "Human", draft.result["title"]
    refute draft.update_field!("title", "Late", expected_version: 1)
  end

  test "recognition only fills blanks in a pending unexpired version" do
    draft = start(caption: "My choice")
    draft.consent!(expected_version: 0)
    refute draft.apply_recognition!(title: "Wrong", price: 50, description: "Info", expected_version: 0)
    assert draft.apply_recognition!(title: "AI", price: 2500, description: "Size 43", expected_version: 1)
    assert_equal "My choice", draft.result["title"]
    assert_equal 2500, draft.result["price"]
    assert_equal "Size 43", draft.result["description"]
    assert_equal "ready", draft.status
    refute draft.apply_recognition!(title: "Again", price: 1, description: nil, expected_version: 2)
  end

  test "new photos retain older drafts while cancellation and expiry reject late jobs" do
    old = start
    old.consent!(expected_version: 0)
    start
    assert_equal "pending", old.reload.status
    old.cancel!(expected_version: 1)
    refute old.apply_recognition!(title: "Late", price: nil, description: nil, expected_version: 1)
    draft = start
    draft.consent!(expected_version: 0)
    draft.update!(expires_at: 1.second.ago)
    refute draft.apply_recognition!(title: "Late", price: nil, description: nil, expected_version: 1)
  end

  test "saving a draft twice publishes once and records the first gift" do
    draft = start(caption: "Lamp")
    draft.manual!(expected_version: 0)
    assert_difference("Item.count", 1) do
      2.times do
        status, item = draft.save_gift!(expected_version: 1)
        assert_includes %i[saved already], status
        assert_equal "source-photo", item.photo_file_id
      end
    end
    assert @user.reload.first_item_at
    assert_nil @user.bot_state
    draft.item.destroy!
    assert_no_difference("Item.count") { assert_nil draft.reload.save_gift!(expected_version: 1).last }
  end

  test "a default list is created only on valid save and uses the draft locale" do
    @list.destroy!
    draft = start
    assert_no_difference("Wishlist.count") { draft.manual!(expected_version: 0) }
    assert_no_difference("Wishlist.count") do
      assert_raises(ActiveRecord::RecordInvalid) { draft.save_gift!(expected_version: 1) }
    end
    draft.update_field!("title", "Lamp", expected_version: 1)
    assert_difference("Wishlist.count", 1) { draft.save_gift!(expected_version: 2) }
    assert_equal "Мои желания", draft.reload.wishlist.title
  end

  test "owned lists only and a removed target is never silently recreated" do
    other = User.create!(telegram_id: 97902).wishlists.create!(title: "Not mine")
    draft = start(caption: "Lamp")
    draft.manual!(expected_version: 0)
    assert_raises(ActiveRecord::RecordNotFound) { draft.select_list!(other.id, expected_version: 1) }
    @list.destroy!
    assert_raises(ActiveRecord::RecordNotFound) { draft.reload.save_gift!(expected_version: 1) }
    assert_equal "ready", draft.reload.status
  end

  test "invalid recognized and manual fields cannot enter the draft" do
    draft = start
    draft.consent!(expected_version: 0)
    assert_raises(ActiveRecord::RecordInvalid) do
      draft.apply_recognition!(title: "Gift", price: -2, description: nil, expected_version: 1)
    end
    assert_nil draft.reload.result["price"]
    assert_raises(ActiveRecord::RecordInvalid) { draft.update_field!("url", "file:///etc/passwd", expected_version: 1) }
    assert_raises(ActiveRecord::RecordInvalid) { draft.update_field!("title", "", expected_version: 1) }
  end

  test "saving an older review does not clear another input" do
    draft = start(caption: "Lamp")
    draft.manual!(expected_version: 0)
    @user.update!(bot_state: "renaming_list", bot_payload: { "wishlist_id" => @list.id })
    draft.save_gift!(expected_version: 1)
    assert_equal "renaming_list", @user.reload.bot_state
  end

  test "caption links can accompany a title and bare shop links are normalized" do
    assert_equal({ "title" => "My lamp", "url" => "https://example.com/lamp" },
      PhotoGiftDraft.caption_result("My lamp\nhttps://example.com/lamp"))
    assert_equal({ "url" => "https://example.com/lamp" }, PhotoGiftDraft.caption_result("example.com/lamp"))
    assert_equal({ "title" => "Lego.Technic" }, PhotoGiftDraft.caption_result("Lego.Technic"))
  end

  test "recognition failures offer a single versioned retry after consent" do
    draft = start
    refute draft.start_recognition!(expected_version: 0)
    draft.consent!(expected_version: 0)
    assert draft.fail_recognition!("timeout", expected_version: 1)
    assert draft.retry_recognition!(expected_version: 2)
    assert_equal "pending", draft.status
    draft.fail_recognition!("timeout", expected_version: 3)
    refute draft.retry_recognition!(expected_version: 4)
    assert_equal "failed", draft.status
  end

  test "routing grants consent atomically only for an owned list and an expected version" do
    draft = start
    foreign = User.create!(telegram_id: 97903).wishlists.create!(title: "Foreign")
    assert_raises(ActiveRecord::RecordNotFound) { draft.choose_destination!(foreign.id, expected_version: 0) }
    assert_nil @user.reload.photo_ai_consented_at
    refute draft.choose_destination!(@list.id, expected_version: 9)
    assert_nil @user.reload.photo_ai_consented_at
    assert draft.choose_destination!(@list.id, expected_version: 0)
    assert @user.reload.photo_ai_consented_at
    assert_equal [ "save", "pending", @list.id, false ],
      [ draft.result["intent"], draft.status, draft.wishlist_id, draft.result["intake_open"] ]
    refute draft.choose_destination!(0, expected_version: 0)
  end

  test "later keeps unconsented photos private and retained for thirty days" do
    draft = start
    assert_equal "later", draft.result["intent"]
    assert_in_delta 30.days, draft.expires_at - draft.created_at, 1
    draft.defer!(expected_version: 0)
    assert_equal "awaiting_consent", draft.status
    assert_nil @user.reload.photo_ai_consented_at
    assert_equal "later", draft.result["intent"]
    assert draft.consent!(expected_version: 1), "bulk consent remains possible"
    assert_equal "pending", draft.status
    assert_equal "later", draft.result["intent"]
  end

  test "list captions ignore case and emoji but never grant implicit consent" do
    @list.update!(title: "🎂 День рождения ✨")
    draft = start(caption: "  ДЕНЬ РОЖДЕНИЯ 🎁 ")
    assert_equal "save", draft.result["intent"]
    assert_equal @list.id, draft.wishlist_id
    assert_nil draft.result["title"]
    assert_nil draft.caption
    assert_equal "awaiting_consent", draft.status
    assert_nil @user.reload.photo_ai_consented_at
    draft.choose_destination!(@list.id, expected_version: 0)
    assert_equal "pending", start(caption: "День рождения").status
  end

  test "ambiguous or foreign list captions stay gift data" do
    @list.update!(title: "🎁 Wishes")
    @user.wishlists.create!(title: "WISHES")
    User.create!(telegram_id: 97904).wishlists.create!(title: "Foreign")
    %w[wishes Foreign].each do |caption|
      draft = start(caption: caption)
      assert_equal "later", draft.result["intent"]
      assert_equal caption, draft.result["title"]
    end
    assert_nil PhotoGiftDraft.list_from_caption(@user, "🎁")
  end

  test "technical screen metadata preserves recognition fields without changing the version" do
    draft = start
    draft.consent!(expected_version: 0)
    stale = PhotoGiftDraft.find(draft.id)
    draft.apply_recognition!(title: "Lamp", price: 250, description: nil, expected_version: 1)
    stale.remember_screen!(123)
    assert_equal 2, draft.reload.version
    assert_equal "Lamp", draft.result["title"]
    assert_equal 123, draft.result["screen_message_id"]
  end

  private

  def start(**attributes)
    @counter += 1
    PhotoGiftDraft.start!(@user, chat_id: @user.telegram_id, message_id: @counter,
      file_id: "source-photo", photo_file_id: "source-photo", **attributes)
  end
end
