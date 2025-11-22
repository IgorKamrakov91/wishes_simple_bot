class Item < ApplicationRecord
  belongs_to :wishlist

  validates :title, presence: true
  validates :price, presence: true, numericality: { greater_than: 0, allow_nil: true }

  def reserver
    User.find_by(telegram_id: reserved_by) if reserved?
  end

  def reserved?
    reserved_by.present?
  end
end
