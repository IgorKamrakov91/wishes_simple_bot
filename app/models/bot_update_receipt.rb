class BotUpdateReceipt < ApplicationRecord
  self.primary_key = :update_id

  RESULT_KINDS = %w[processed list_view item_view list_created list_renamed list_deleted gift_added gift_updated gift_deleted
    reserved released purchased unpurchased thanked settings_updated reminder_updated].freeze

  validates :telegram_user_id, presence: true
  validates :result_kind, inclusion: { in: RESULT_KINDS }

  def mark_delivered!
    update!(delivered_at: Time.current)
  end
end
