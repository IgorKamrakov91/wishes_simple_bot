# Reads one pending photo draft with the vision model and sends the filled-in
# review. Each pending version is read at most once: a repeated or late job,
# or one for a draft the person has since edited, cancelled or replaced,
# neither calls the model nor touches the draft.
class PhotoGiftRecognitionJob < ApplicationJob
  queue_as :default
  self.log_arguments = false
  # Shares the gift ideas slots: at most two model calls at a time, so the
  # three worker threads always keep one for notifications and reminders.
  limits_concurrency to: 2, key: "gift_ideas", group: "gift_ideas", duration: 2.minutes

  LIMIT_CODES = { disabled: "disabled", global_limit: "limit", kind_limit: "limit", user_limit: "user_limit" }.freeze

  def perform(draft_id, version)
    draft = PhotoGiftDraft.find_by(id: draft_id)
    return unless draft && claim(draft, version)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    outcome, shown_version = recognize(draft, version)
    log(draft, outcome, started)
    PhotoGiftReviewJob.perform_later(draft.id, shown_version) if shown_version
  end

  private

  # Marks the version as taken under the draft's lock, so two copies of the
  # job can't both call the model
  def claim(draft, version)
    draft.with_lock do
      next false unless PhotoGiftDraft.enabled? && draft.editable? && draft.status == "pending" &&
        draft.version == version && draft.result["claimed_version"] != version

      draft.update!(result: draft.result.merge("claimed_version" => version))
    end
  end

  def recognize(draft, version)
    reserved = AiCall.reserve!(draft.user, :photo)
    return fail(draft, LIMIT_CODES.fetch(reserved), version) unless reserved == :created

    image = Bot::TelegramFile.new.download(draft.file_id)
    found = YandexAi::PhotoReader.new.call(image, caption: draft.caption)
    return fail(draft, "no_product", version) unless found

    applied = draft.apply_recognition!(title: found.title, price: found.price&.to_s("F"),
                                       description: found.description, expected_version: version)
    return [ "stale", nil ] unless applied

    save_if_list_chosen(draft, version + 1)
  rescue YandexAi::Client::Error => e
    fail(draft, e.code, version)
  rescue Bot::TelegramFile::Error => e
    fail(draft, "file_#{e.message}", version)
  rescue ActiveRecord::RecordInvalid
    fail(draft, "invalid", version)
  rescue StandardError => e
    Rails.logger.error("Photo gift #{draft.id} recognition failed (#{e.class})")
    fail(draft, "error", version)
  end

  # The person picked a list when sending the photo: that choice is the
  # go-ahead to publish without the review. A photo still being prepared,
  # or a draft changed meanwhile, falls back to the review.
  def save_if_list_chosen(draft, version)
    return [ "ready", version ] unless draft.reload.result["intent"] == "save"

    status, = draft.save_gift!(expected_version: version)
    status == :saved ? [ "saved", draft.version ] : [ "ready", version ]
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound
    # e.g. the chosen list was deleted meanwhile
    [ "ready", version ]
  end

  # Returns the outcome and the draft version to show, when this job changed
  # the draft (each change moves it exactly one version on)
  def fail(draft, code, version)
    [ code, (version + 1 if draft.fail_recognition!(code, expected_version: version) == true) ]
  end

  def log(draft, outcome, started)
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    Rails.logger.info("Photo gift #{draft.id}: #{outcome} in #{ms} ms")
  end
end
