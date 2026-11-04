class Item < ApplicationRecord
  EDITABLE_FIELDS = %w[title description url price].freeze

  belongs_to :wishlist

  scope :accessible_to, ->(user) { where(wishlist_id: Wishlist.accessible_to(user).select(:id)) }

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

  # Return whether this request changed the reservation. The version comes from
  # the button's snapshot, so delayed requests cannot affect a newer booking.
  def reserve_for!(user, expected_version: reservation_version)
    change_reservation(nil, user.telegram_id, expected_version)
  end

  def release_for!(user, expected_version: reservation_version)
    change_reservation(user.telegram_id, nil, expected_version)
  end

  private

  def change_reservation(previous_reserver, next_reserver, expected_version)
    changed = self.class.where(id: id, reserved_by: previous_reserver, reservation_version: expected_version)
      .update_all(reserved_by: next_reserver, reservation_version: expected_version + 1, updated_at: Time.current) == 1

    reload
    changed
  end
end
