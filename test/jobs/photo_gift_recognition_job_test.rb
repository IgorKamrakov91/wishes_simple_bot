require "test_helper"
require "mocha/minitest"

class PhotoGiftRecognitionJobTest < ActiveJob::TestCase
  Result = YandexAi::PhotoReader::Result

  setup do
    @env = ENV.to_h.slice("TELEGRAM_BOT_TOKEN", "PHOTO_GIFTS_ENABLED")
    ENV["TELEGRAM_BOT_TOKEN"] = "token"
    ENV["PHOTO_GIFTS_ENABLED"] = "true"
    GiftSuggestion.stubs(:enabled?).returns(true)
    @owner = User.create!(telegram_id: 97_301, first_name: "Owner", photo_ai_consented_at: Time.current)
    @list = @owner.wishlists.create!(title: "Birthday")
    @sent = []
    @api = stub("api")
    @api.stubs(:send_message).with { |params| @sent << params; true }
    @edited = []
    @api.stubs(:edit_message_text).with { |params| @edited << params; true }
    Telegram::Bot::Client.stubs(:new).returns(stub(api: @api))
    @files = stub("files")
    @files.stubs(:download).returns("\xFF\xD8\xFFjpeg".b)
    Bot::TelegramFile.stubs(:new).returns(@files)
    @reader = stub("reader")
    YandexAi::PhotoReader.stubs(:new).returns(@reader)
  end

  teardown { @env.each { |key, value| ENV[key] = value } }

  def recognize(id, version)
    perform_enqueued_jobs(only: PhotoGiftReviewJob) { PhotoGiftRecognitionJob.perform_now(id, version) }
  end

  def start(caption: nil)
    draft = nil
    assert_enqueued_jobs(1, only: PhotoGiftRecognitionJob) do
      draft = PhotoGiftDraft.start!(@owner, chat_id: @owner.telegram_id, message_id: 10 + PhotoGiftDraft.count,
        file_id: "photo-large", file_unique_id: "u", photo_file_id: "photo-large", media_kind: "photo",
        media_status: "ready", caption: caption)
    end
    assert_equal "pending", draft.status
    draft
  end

  test "fills the draft, counts the call and sends the review" do
    draft = start
    @reader.expects(:call).with("\xFF\xD8\xFFjpeg".b, caption: nil)
      .returns(Result.new(title: "Ботинки BOSS", price: BigDecimal("20990"), description: "Детали: размер 43"))

    assert_difference("AiCall.count") { recognize(draft.id, draft.version) }

    draft.reload
    assert_equal "ready", draft.status
    assert_equal({ "title" => "Ботинки BOSS", "price" => "20990.0", "description" => "Детали: размер 43" }, draft.fields)
    assert_equal 1, @sent.size
    assert_equal @owner.telegram_id, @sent.last[:chat_id]
    assert_includes @sent.last[:text], "Ботинки BOSS"
    assert_includes @sent.last[:text], "≈ 20"
    assert_equal 0, Item.count, "nothing is published before the person saves"
  end

  test "the person's caption wins over the model" do
    draft = start(caption: "Ботинки на зиму")
    @reader.expects(:call).with(anything, caption: "Ботинки на зиму")
      .returns(Result.new(title: "Ботинки BOSS", price: BigDecimal("20990"), description: nil))

    recognize(draft.id, draft.version)

    assert_equal "Ботинки на зиму", draft.reload.fields["title"]
    assert_equal "20990.0", draft.fields["price"]
  end

  test "a repeated job calls the model once" do
    draft = start
    version = draft.version
    @reader.expects(:call).once.returns(Result.new(title: "Лампа", price: nil, description: nil))

    recognize(draft.id, version)
    recognize(draft.id, version)

    assert_equal 1, @sent.size
  end

  test "a draft the person moved on from is left alone" do
    draft = start
    version = draft.version
    draft.manual!(expected_version: version)
    @reader.expects(:call).never
    @files.expects(:download).never

    assert_no_difference("AiCall.count") { recognize(draft.id, version) }
    assert_equal "ready", draft.reload.status
    assert_empty @sent
  end

  test "an edit during recognition beats the late result" do
    draft = start
    version = draft.version
    @reader.expects(:call).with do
      draft.update_field!("title", "Мой вариант", expected_version: draft.reload.version)
      true
    end.returns(Result.new(title: "Лампа", price: BigDecimal("100"), description: nil))

    recognize(draft.id, version)

    assert_equal({ "title" => "Мой вариант" }, draft.reload.fields)
    assert_empty @sent, "the person is already looking at their own edit"
  end

  test "the daily cap fails the draft into the manual review without downloading" do
    draft = start
    AiCall.stubs(:reserve!).returns(:user_limit)
    @files.expects(:download).never

    recognize(draft.id, draft.version)

    assert_equal [ "failed", "user_limit" ], [ draft.reload.status, draft.error_code ]
    assert_includes @sent.last[:text], I18n.t("bot.photo_gift.failed_limit")
  end

  test "model errors, empty pictures and broken downloads fail with a retry" do
    { YandexAi::Client::Error.new("timeout") => "timeout", nil => "no_product",
      Bot::TelegramFile::Error.new("too_large") => "file_too_large" }.each do |problem, code|
      draft = start
      if problem.is_a?(Bot::TelegramFile::Error)
        @files.stubs(:download).raises(problem)
      elsif problem
        @reader.stubs(:call).raises(problem)
      else
        @reader.stubs(:call).returns(nil)
      end

      recognize(draft.id, draft.version)

      assert_equal [ "failed", code ], [ draft.reload.status, draft.error_code ]
      assert_includes @sent.last[:text], I18n.t("bot.photo_gift.failed")
      buttons = @sent.last[:reply_markup].inline_keyboard.flatten.map(&:callback_data)
      assert_includes buttons, "pg:r:#{draft.id}:#{draft.version}"
      @files.unstub(:download)
      @files.stubs(:download).returns("\xFF\xD8\xFFjpeg".b)
    end
  end

  test "a retry is read again" do
    draft = start
    @reader.stubs(:call).raises(YandexAi::Client::Error.new("timeout"))
    recognize(draft.id, draft.version)

    assert_enqueued_with(job: PhotoGiftRecognitionJob) { draft.reload.retry_recognition!(expected_version: draft.version) }
    @reader.stubs(:call).returns(Result.new(title: "Лампа", price: nil, description: nil))
    recognize(draft.id, draft.reload.version)
    assert_equal [ "ready", "Лампа" ], [ draft.reload.status, draft.fields["title"] ]
  end

  test "an undelivered review is retried and the result kept" do
    draft = start
    @reader.expects(:call).once.returns(Result.new(title: "Лампа", price: nil, description: nil))
    @api.expects(:send_message).times(3).raises(Faraday::TimeoutError)

    recognize(draft.id, draft.version)
    assert_equal "ready", draft.reload.status
  end

  test "a draft closed before delivery gets no late review" do
    draft = start
    version = draft.version
    @reader.stubs(:call).returns(Result.new(title: "Лампа", price: nil, description: nil))
    PhotoGiftRecognitionJob.perform_now(draft.id, version)
    draft.reload.cancel!(expected_version: draft.version)

    perform_enqueued_jobs(only: PhotoGiftReviewJob)
    assert_empty @sent
  end

  test "a stalled draft stays manual after other changes" do
    draft = start
    travel 3.minutes do
      draft.reload.remove_photo!(expected_version: draft.version)
      assert draft.reload.recognition_stalled?
      context = Object.new.extend(Bot::Helpers)
      assert_includes Bot::Presenters::PhotoGiftPresenter.new(draft, @owner, context).text, I18n.t("bot.photo_gift.review")
    end
  end

  test "switching the feature off stops queued work" do
    draft = start
    ENV["PHOTO_GIFTS_ENABLED"] = "false"
    @reader.expects(:call).never
    recognize(draft.id, draft.version)
    assert_equal "pending", draft.reload.status
  end

  test "a stalled draft offers the manual review" do
    draft = start
    context = Object.new.extend(Bot::Helpers)
    presenter = -> { Bot::Presenters::PhotoGiftPresenter.new(draft, @owner, context) }
    assert_includes presenter.call.text, I18n.t("bot.photo_gift.recognizing")

    travel 3.minutes
    assert_includes presenter.call.text, I18n.t("bot.photo_gift.review")
  end

  test "a list picked with the photo saves the gift on its own and edits the same message" do
    draft = start
    draft.update!(result: draft.result.merge("intent" => "save", "screen_message_id" => 555))
    @reader.stubs(:call).returns(Result.new(title: "Ботинки BOSS", price: BigDecimal("20990"), description: "Детали: 43"))

    assert_difference("@list.items.count") { recognize(draft.id, draft.version) }

    item = @list.items.last
    assert_equal [ "Ботинки BOSS", BigDecimal("20990"), "photo-large" ], [ item.title, item.price, item.photo_file_id ]
    assert_equal "saved", draft.reload.status
    assert_empty @sent
    assert_equal 555, @edited.last[:message_id]
    assert_includes @edited.last[:text], "Ботинки BOSS"
    assert_includes @edited.last[:text], "Birthday"
    buttons = @edited.last[:reply_markup].inline_keyboard.flatten.map(&:callback_data)
    assert_equal [ "open_item:#{item.id}", "pgu:#{draft.id}" ], buttons
  end

  test "without a chosen list the review replaces the same message, or comes anew" do
    draft = start
    draft.update!(result: draft.result.merge("screen_message_id" => 555))
    @reader.stubs(:call).returns(Result.new(title: "Лампа", price: nil, description: nil))
    @api.stubs(:edit_message_text).raises(Telegram::Bot::Exceptions::ResponseError.new(response: stub(status: 400, body: {}.to_json)))

    assert_no_difference("Item.count") { recognize(draft.id, draft.version) }
    assert_equal "ready", draft.reload.status
    assert_includes @sent.last[:text], "Лампа"
  end

  test "a chosen list deleted meanwhile falls back to the review" do
    draft = start
    draft.update!(result: draft.result.merge("intent" => "save"))
    @reader.stubs(:call).with { @list.destroy!; true }.returns(Result.new(title: "Лампа", price: nil, description: nil))

    assert_no_difference("Item.count") { recognize(draft.id, draft.version) }
    assert_equal "ready", draft.reload.status
    assert_includes @sent.last[:text], "Лампа"
  end
end
