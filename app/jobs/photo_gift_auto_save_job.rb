# Saves a recognized photo draft on its own once the person has picked a
# list, whatever finished last: recognition, the list choice or preparing a
# photo sent as a file. Shows "Added …", or the review when saving can't
# happen (the photo is still being prepared, the list is gone, a value is
# invalid).
class PhotoGiftAutoSaveJob < ApplicationJob
  queue_as :default
  self.log_arguments = false

  def perform(draft_id, version)
    draft = PhotoGiftDraft.find_by(id: draft_id)
    return unless draft&.auto_save_due? && draft.version == version

    status, = draft.save_gift!(expected_version: version)
    PhotoGiftReviewJob.perform_later(draft.id, status == :saved ? draft.version : version)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound
    PhotoGiftReviewJob.perform_later(draft.id, version)
  end
end
