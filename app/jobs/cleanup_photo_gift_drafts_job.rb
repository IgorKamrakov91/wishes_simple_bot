class CleanupPhotoGiftDraftsJob < ApplicationJob
  def perform
    PhotoGiftDraft.where(media_status: %w[pending processing]).where(updated_at: ..2.minutes.ago)
      .update_all(media_status: "failed")
    expired = PhotoGiftDraft.where(expires_at: ..Time.current)
    User.where(id: expired.select(:user_id)).find_each do |user|
      user.with_lock do
        id = user.bot_payload&.dig("photo_gift_draft_id")
        if %w[photo_gift editing_photo_gift].include?(user.bot_state) && expired.where(user_id: user.id, id: id).exists?
          user.update!(bot_state: nil, bot_payload: nil)
        end
      end
    end
    expired.delete_all
  end
end
