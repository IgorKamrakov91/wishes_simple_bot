# Every evening: one digest per person with photo drafts they sent and left
# since the last digest. Each draft is in at most one digest.
class PhotoInboxDigestsJob < ApplicationJob
  queue_as :reminders

  def perform
    return unless PhotoGiftDraft.enabled?

    PhotoGiftDraft.for_digest.distinct.pluck(:user_id).each do |user_id|
      PhotoInboxDigestJob.perform_later(user_id)
    end
  end
end
