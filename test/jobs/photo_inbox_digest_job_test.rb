require "test_helper"
require "mocha/minitest"
require "telegram/bot"

Telegram::Bot::Types::Update

class PhotoInboxDigestJobTest < ActiveJob::TestCase
  setup do
    @env = ENV.to_h.slice("TELEGRAM_BOT_TOKEN", "PHOTO_GIFTS_ENABLED")
    ENV["TELEGRAM_BOT_TOKEN"] = "token"
    ENV["PHOTO_GIFTS_ENABLED"] = "true"
    @owner = User.create!(telegram_id: 97_601, first_name: "Owner", photo_ai_consented_at: Time.current)
    @list = @owner.wishlists.create!(title: "Birthday")
    @sent = []
    @api = stub("api")
    @api.stubs(:send_message).with { |params| @sent << params; true }
    @api.stubs(:edit_message_text).with { |params| @sent << params; true }
    @api.stubs(:answer_callback_query)
    Telegram::Bot::Client.stubs(:new).returns(stub(api: @api))
    @message_id = 0
  end

  teardown { @env.each { |key, value| ENV[key] = value } }

  def draft(user: @owner, status: "ready", fields: {}, **attributes)
    @message_id += 1
    PhotoGiftDraft.create!(user: user, wishlist: user.wishlists.first, status: status, result: fields,
      chat_id: user.telegram_id, message_id: @message_id, file_id: "f#{@message_id}", photo_file_id: "p#{@message_id}",
      media_kind: "photo", media_status: "ready", locale: "ru", expires_at: 30.days.from_now, **attributes)
  end

  def buttons
    @sent.last[:reply_markup].inline_keyboard.flatten.map(&:callback_data)
  end

  test "each person with new left photos gets one digest" do
    other = User.create!(telegram_id: 97_602, first_name: "Other")
    draft(fields: { "title" => "Лампа" })
    draft(fields: { "title" => "Плед" })
    draft(user: other, status: "awaiting_consent")
    draft(status: "pending")
    draft(status: "saved")
    draft(fields: { "title" => "Old" }, expires_at: 1.minute.ago)
    draft(fields: { "title" => "Seen", "digested_at" => 1.day.ago.iso8601 })

    assert_enqueued_jobs(2, only: PhotoInboxDigestJob) { PhotoInboxDigestsJob.perform_now }
  end

  test "the digest lists the photos, offers saving all to the latest list and is sent once" do
    draft(fields: { "title" => "Ботинки BOSS", "price" => "20990.0" })
    draft(status: "failed")

    PhotoInboxDigestJob.perform_now(@owner.id)
    PhotoInboxDigestJob.perform_now(@owner.id)

    assert_equal 1, @sent.size
    text = @sent.last[:text]
    assert_includes text, "Ботинки BOSS — ≈ 20"
    assert_includes text, I18n.t("bot.photo_inbox.unnamed")
    assert_equal [ "pgd:s:#{@list.id}", "pgi:0" ], buttons
  end

  test "without consent the digest asks for it" do
    @owner.update!(photo_ai_consented_at: nil)
    draft(status: "awaiting_consent")

    PhotoInboxDigestJob.perform_now(@owner.id)

    assert_includes @sent.last[:text], I18n.t("bot.photo_inbox.needs_consent")
    assert_equal [ "pgd:c", "pgi:0" ], buttons
  end

  test "saving all keeps unnamed photos in the inbox" do
    named = draft(fields: { "title" => "Лампа", "price" => "100" })
    unnamed = draft(status: "failed")

    assert_difference("@list.items.count", 1) { press("pgd:s:#{@list.id}") }

    assert_equal "saved", named.reload.status
    assert_equal "p#{named.message_id}", named.item.photo_file_id
    assert_equal "failed", unnamed.reload.status
    assert_includes @sent.last[:text], "Сохранил 1 подарок"
    assert_includes @sent.last[:text], "осталось 1 фото"
  end

  test "saving all without lists makes My wishes once" do
    @list.destroy!
    2.times { |i| draft(fields: { "title" => "Gift #{i}" }) }

    assert_difference("Wishlist.count", 1) { press("pgd:s:0") }
    assert_equal 2, @owner.wishlists.sole.items.count
  end

  test "allowing recognition reads every photo that waited" do
    @owner.update!(photo_ai_consented_at: nil)
    2.times { draft(status: "awaiting_consent") }

    assert_enqueued_jobs(2, only: PhotoGiftRecognitionJob) { press("pgd:c") }
    assert @owner.reload.photo_ai_consented_at
    assert_equal %w[pending pending], @owner.photo_gift_drafts.pluck(:status)
  end

  test "someone else's list can't be the target" do
    other = User.create!(telegram_id: 97_603, first_name: "Other")
    foreign = other.wishlists.create!(title: "Foreign")
    draft(fields: { "title" => "Лампа" })

    assert_no_difference("Item.count") { press("pgd:s:#{foreign.id}") }
  end

  test "an undelivered digest is retried with the same photos" do
    named = draft(fields: { "title" => "Лампа" })
    @api.stubs(:send_message).raises(Faraday::TimeoutError)

    assert_enqueued_jobs(1, only: PhotoInboxDigestJob) { PhotoInboxDigestJob.perform_now(@owner.id) }
    refute named.reload.result.key?("digested_at")

    @api.unstub(:send_message)
    @api.stubs(:send_message).with { |params| @sent << params; true }
    perform_enqueued_jobs(only: PhotoInboxDigestJob)
    assert_includes @sent.last[:text], "Лампа"
  end

  test "a person who blocked the bot isn't retried" do
    named = draft(fields: { "title" => "Лампа" })
    blocked = Telegram::Bot::Exceptions::ResponseError.new(response: stub(status: 403, body: { error_code: 403 }.to_json))
    @api.stubs(:send_message).raises(blocked)

    assert_no_enqueued_jobs(only: PhotoInboxDigestJob) { PhotoInboxDigestJob.perform_now(@owner.id) }
    assert named.reload.result.key?("digested_at")
  end

  private

  def press(data)
    @message_id += 1
    Bot::Dispatcher.dispatch(stub(api: @api), Telegram::Bot::Types::Update.new(update_id: 97_600_000 + @message_id, callback_query: {
      id: @message_id.to_s, chat_instance: "chat", data: data,
      from: { id: @owner.telegram_id, is_bot: false, first_name: "Owner" },
      message: { message_id: 1, date: 1, chat: { id: @owner.telegram_id, type: "private" }, text: "Digest" }
    }))
  end
end
