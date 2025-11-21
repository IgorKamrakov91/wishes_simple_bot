class ListViewer < ApplicationRecord
  belongs_to :wishlist

  validates :telegram_id, presence: true

  def self.touch_viewer(wishlist_id:, telegram_id:)
    find_or_initialize_by(wishlist_id: wishlist_id, telegram_id: telegram_id).tap do |viewer|
      viewer.update!(last_opened_at: Time.current)
    end
  end
end