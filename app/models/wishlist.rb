class Wishlist < ApplicationRecord
  belongs_to :user
  has_many :items, dependent: :destroy
  has_many :list_viewers, dependent: :destroy

  validates :title, presence: true

  def owner
    user
  end
end
