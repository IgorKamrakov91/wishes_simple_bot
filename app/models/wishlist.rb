class Wishlist < ApplicationRecord
  belongs_to :user
  has_many :items, dependent: :destroy
  has_many :list_viewers, dependent: :destroy
  has_many :viewers, through: :list_viewers, source: :user

  validates :title, presence: true

  def owner
    user
  end

  def has_viewer?(user)
    list_viewers.exists?(user: user)
  end
end
