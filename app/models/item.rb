class Item < ApplicationRecord
  EDITABLE_FIELDS = %w[title description url price].freeze

  belongs_to :wishlist

  validates :title, presence: true
  validates :price, numericality: { greater_than: 0, allow_nil: true, default: 0 }

  def reserver
    User.find_by(telegram_id: reserved_by) if reserved?
  end

  def reserved?
    reserved_by.present?
  end

  def reserved_by?(user)
    reserved_by == user.telegram_id
  end

  def reserved_by_other?(user)
    reserved? && !reserved_by?(user)
  end

  def reserve_for!(user)
    update!(reserved_by: user.telegram_id)
  end

  def release_reservation!
    update!(reserved_by: nil)
  end
end
