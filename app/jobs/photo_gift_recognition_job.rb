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
    outcome, changed = recognize(draft, version)
    log(draft, outcome, started)
    # Every change this job makes moves the draft exactly one version on
    PhotoGiftReviewJob.perform_later(draft.id, version + 1) if changed
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
    applied ? [ "ready", true ] : [ "stale", false ]
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

  # Returns the outcome and whether this job changed the draft
  def fail(draft, code, version)
    [ code, draft.fail_recognition!(code, expected_version: version) == true ]
  end

  def log(draft, outcome, started)
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    Rails.logger.info("Photo gift #{draft.id}: #{outcome} in #{ms} ms")
  end
end
