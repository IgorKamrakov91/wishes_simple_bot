require "telegram/bot"

class PhotoGiftDocumentJob < ApplicationJob
  self.log_arguments = false

  def perform(draft_id)
    draft = PhotoGiftDraft.find_by(id: draft_id)
    return unless PhotoGiftDraft.enabled? && draft&.editable?
    return unless PhotoGiftDraft.active.where(id: draft.id, media_status: "pending").update_all(media_status: "processing") == 1

    api = Telegram::Bot::Client.new(ENV.fetch("TELEGRAM_BOT_TOKEN")).api
    photo_id = Bot::PhotoGiftDocument.new(api: api).prepare(draft)
    draft.with_lock do
      return unless draft.editable? && !draft.result["without_photo"]

      draft.update!(photo_file_id: photo_id, media_status: "ready")
    end
  rescue StandardError => e
    # Exception text may include file contents, paths, or Telegram credentials.
    Rails.logger.warn("Photo gift document preparation failed (#{e.class})")
    PhotoGiftDraft.where(id: draft_id, media_status: "processing").update_all(media_status: "failed")
  end
end
