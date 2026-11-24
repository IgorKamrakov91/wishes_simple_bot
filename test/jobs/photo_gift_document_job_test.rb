require "test_helper"
require "mocha/minitest"
require "telegram/bot"

class PhotoGiftDocumentJobTest < ActiveJob::TestCase
  setup do
    @flag = ENV["PHOTO_GIFTS_ENABLED"]
    @token = ENV["TELEGRAM_BOT_TOKEN"]
    ENV["PHOTO_GIFTS_ENABLED"] = "true"
    ENV["TELEGRAM_BOT_TOKEN"] = "test-token"
    @user = User.create!(telegram_id: 97931)
    @draft = PhotoGiftDraft.start!(@user, chat_id: 97931, message_id: 1, file_id: "document",
      media_kind: "document", media_status: "pending")
    Telegram::Bot::Client.stubs(:new).returns(stub(api: stub))
    @processor = mock
    Bot::PhotoGiftDocument.stubs(:new).returns(@processor)
  end

  teardown do
    ENV["PHOTO_GIFTS_ENABLED"] = @flag
    ENV["TELEGRAM_BOT_TOKEN"] = @token
  end

  test "conversion is claimed once without recognition or gift creation" do
    @processor.expects(:prepare).once.returns("converted-photo")
    assert_no_difference("Item.count") { 2.times { PhotoGiftDocumentJob.perform_now(@draft.id) } }
    assert_equal "converted-photo", @draft.reload.photo_file_id
    assert_equal "ready", @draft.media_status
    assert_equal "awaiting_consent", @draft.status
  end

  test "conversion failure keeps manual fields and supports saving without a photo" do
    @draft.manual!(expected_version: 0)
    @draft.update_field!("title", "Lamp", expected_version: 1)
    @processor.expects(:prepare).raises(Bot::PhotoGiftDocument::InvalidImage)
    PhotoGiftDocumentJob.perform_now(@draft.id)
    assert_equal "failed", @draft.reload.media_status
    assert_equal :photo_pending, @draft.save_gift!(expected_version: 2).first
    @draft.remove_photo!(expected_version: 2)
    assert_equal :saved, @draft.save_gift!(expected_version: 3).first
    assert_nil @draft.item.photo_file_id
  end

  test "cancelled and expired files are not downloaded" do
    @processor.expects(:prepare).never
    @draft.cancel!(expected_version: 0)
    PhotoGiftDocumentJob.perform_now(@draft.id)
  end

  test "late conversion cannot attach an image after removal or cancellation" do
    @processor.expects(:prepare).with do |_draft|
      @draft.remove_photo!(expected_version: 0)
      true
    end.returns("late-photo")
    PhotoGiftDocumentJob.perform_now(@draft.id)
    assert_nil @draft.reload.photo_file_id
  end

  test "cleanup removes expired drafts without deleting their saved gift" do
    @draft.manual!(expected_version: 0)
    @draft.update_field!("title", "Lamp", expected_version: 1)
    @draft.remove_photo!(expected_version: 2)
    @draft.save_gift!(expected_version: 3)
    item = @draft.item
    @draft.update!(expires_at: 1.second.ago)
    CleanupPhotoGiftDraftsJob.perform_now
    refute PhotoGiftDraft.exists?(@draft.id)
    assert Item.exists?(item.id)
  end

  test "cleanup clears only the expired photo input and preserves another user's input" do
    other = User.create!(telegram_id: 97932, bot_state: "creating_list")
    @draft.update!(expires_at: 1.second.ago)
    CleanupPhotoGiftDraftsJob.perform_now
    assert_nil @user.reload.bot_state
    assert_equal "creating_list", other.reload.bot_state
  end
end
