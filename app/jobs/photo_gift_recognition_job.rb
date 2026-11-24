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

  TAKEOVER_WAIT = 15.seconds
  LIMIT_CODES = { disabled: "disabled", global_limit: "limit", kind_limit: "limit", user_limit: "user_limit" }.freeze

  def perform(draft_id, version)
    draft = PhotoGiftDraft.find_by(id: draft_id)
    return unless draft

    if reading_earlier_version?(draft, version)
      # Usually that job takes this version over when it finishes; if it
      # died, this one does the work a little later
      return self.class.set(wait: TAKEOVER_WAIT).perform_later(draft_id, version)
    end
    return unless claim(draft, version)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    outcome, shown_version = recognize(draft, version)
    log(draft, outcome, started)
    PhotoGiftReviewJob.perform_later(draft.id, shown_version) if shown_version
  ensure
    # No longer reading: a retry or newer version must not wait for this job
    PhotoGiftDraft.where(id: draft.id).update_all("result = result - 'claimed_at'") if draft && outcome
  end

  private

  # Marks the version as taken under the draft's lock, so two copies of the
  # job can't both call the model
  def claim(draft, version)
    draft.with_lock do
      next false unless PhotoGiftDraft.enabled? && draft.editable? && draft.status == "pending" &&
        draft.version == version && draft.result["claimed_version"] != version

      draft.update!(result: draft.result.merge("claimed_version" => version, "claimed_at" => Time.current.iso8601(3)))
    end
  end

  # Another job is still reading this photo for an older version of the draft
  def reading_earlier_version?(draft, version)
    claimed = draft.result["claimed_version"]
    claimed_at = Time.zone.parse(draft.result["claimed_at"].to_s) rescue nil
    claimed.is_a?(Integer) && claimed < version && claimed_at && claimed_at > PhotoGiftDraft::RECOGNITION_DEADLINE.ago
  end

  def recognize(draft, version)
    reserved = AiCall.reserve!(draft.user, :photo)
    return fail(draft, LIMIT_CODES.fetch(reserved), version) unless reserved == :created

    image = Bot::TelegramFile.new.download(draft.file_id)
    found = YandexAi::PhotoReader.new.call(image, caption: draft.caption)
    return fail(draft, "no_product", version) unless found

    apply_latest(draft, version, found)
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

  # Picking a list or "later" while the model reads moves the version on but
  # keeps the draft pending. The answer still fits it: take the new version
  # over (its own job then finds it claimed) instead of a second model call.
  # Edits, cancellation or replacement leave the draft non-pending and win.
  def apply_latest(draft, version, found)
    3.times do
      if draft.apply_recognition!(title: found.title, price: found.price&.to_s("F"),
                                  description: found.description, expected_version: version)
        return save_if_list_chosen(draft, version + 1)
      end
      draft.reload
      return [ "stale", nil ] unless claim(draft, draft.version)

      version = draft.version
    end
    [ "stale", nil ]
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
