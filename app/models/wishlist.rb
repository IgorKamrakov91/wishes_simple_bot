require "cgi"

class Wishlist < ApplicationRecord
  belongs_to :user
  has_many :items, -> { order(:id) }, dependent: :destroy
  has_many :list_viewers, dependent: :destroy
  has_many :viewers, through: :list_viewers, source: :user

  # Share links carry this token instead of the guessable id
  has_secure_token :share_token, length: 24

  scope :shared_with, ->(user) { joins(:list_viewers).where(list_viewers: { user_id: user.id }) }
  # Lists the user owns or was let into with a share link
  scope :accessible_to, ->(user) {
    where(user_id: user.id).or(where(id: ListViewer.where(user_id: user.id).select(:wishlist_id)))
  }

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

  # Opening the share link is what lets a guest in
  def admit!(user)
    return if user_id == user.id

    list_viewers.find_or_create_by!(user: user)
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
