class Item < ApplicationRecord
  belongs_to :wishlist

  validates :title, presence: true

  def reserver
    User.find_by(telegram_id: reserved_by) if reserved?
  end

  def reserved?
    reserved_by.present?
  end
end