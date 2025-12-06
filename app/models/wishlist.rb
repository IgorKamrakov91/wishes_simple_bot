class Wishlist < ApplicationRecord
  belongs_to :user
  has_many :items, dependent: :destroy
  has_many :list_viewers, dependent: :destroy
  has_many :viewers, through: :list_viewers, source: :user

  validates :title, presence: true

  def owner
    user
  end

  def owner_link
    "<a href=\"tg://user?id=#{owner.telegram_id}\">#{owner.full_name}</a>"
  end

  def has_viewer?(user)
    list_viewers.exists?(user: user)
  end

  def reserved_items_count
    items.where.not(reserved_by: nil).count
  end

  def percentage_fulfilled
    return 0 if items.empty?
    (reserved_items_count.to_f / items.count.to_f * 100).round
  end
end
