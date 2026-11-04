class Wishlist < ApplicationRecord
  belongs_to :user
  has_many :items, -> { order(:id) }, dependent: :destroy
  has_many :list_viewers, dependent: :destroy
  has_many :viewers, through: :list_viewers, source: :user

  scope :shared_with, ->(user) { joins(:list_viewers).where(list_viewers: { user_id: user.id }) }

  validates :title, presence: true

  def owner
    user
  end

  def owner_link
    "<a href=\"tg://user?id=#{owner.telegram_id}\">#{CGI.escapeHTML(owner.full_name)}</a>"
  end

  def has_viewer?(user)
    list_viewers.exists?(user: user)
  end

  # Both work on the loaded association, so `includes(:items)` avoids extra queries
  def reserved_items_count
    items.count(&:reserved?)
  end

  def percentage_fulfilled
    return 0 if items.empty?
    (reserved_items_count.to_f / items.size * 100).round
  end
end
