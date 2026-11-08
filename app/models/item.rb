class Item < ApplicationRecord
  EDITABLE_FIELDS = %w[title description url price].freeze
  OPTIONAL_FIELDS = %w[description url price].freeze
  TITLE_LIMIT = 100
  DESCRIPTION_LIMIT = 1000
  URL_LIMIT = 2000
  PRICE_LIMIT = 100_000_000

  belongs_to :wishlist

  scope :accessible_to, ->(user) { where(wishlist_id: Wishlist.accessible_to(user).select(:id)) }

  # Limits apply to new values only, so older data stays editable
  validates :title, presence: true
  validates :title, length: { maximum: TITLE_LIMIT }, if: :title_changed?
  validates :description, length: { maximum: DESCRIPTION_LIMIT }, if: :description_changed?
  validates :url, length: { maximum: URL_LIMIT }, allow_nil: true, if: :url_changed?
  validate :url_opens_in_a_browser, if: -> { url.present? && url_changed? }
  validates :price, numericality: { greater_than: 0, less_than: PRICE_LIMIT, allow_nil: true }

  # The same parsing decides whether a link is accepted and whether the card
  # can show it as a store button. Letters outside ASCII in the path (as
  # copied from an address bar) are percent-encoded; the host must be ASCII.
  def self.web_uri(value)
    text = value.to_s.strip
    return if text.empty?

    uri = URI.parse(text.gsub(/[^\x00-\x7F]+/) { |part| ERB::Util.url_encode(part) })
    uri if uri.is_a?(URI::HTTP) && uri.host.to_s.match?(/\A[a-z0-9-]+(\.[a-z0-9-]+)+\z/i)
  rescue URI::Error
    nil
  end

  def web_uri
    self.class.web_uri(url)
  end

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

  def purchased?
    purchased_at.present?
  end

  # Only the guest holding this reservation can mark it. A real change bumps
  # the version like reserve/release do, so a late repeat of an earlier press
  # can't undo a later choice, and older buttons stop working. Repeating the
  # last press changes nothing and still reports the mark as it is.
  def mark_purchased_by!(user, purchased, expected_version: reservation_version)
    scope = self.class.where(id: id, reserved_by: user.telegram_id, reservation_version: expected_version)
    scope = purchased ? scope.where(purchased_at: nil) : scope.where.not(purchased_at: nil)
    changed = scope.update_all(purchased_at: (Time.current if purchased),
                               reservation_version: expected_version + 1, updated_at: Time.current) == 1
    reload
    changed || (reserved_by?(user) && purchased? == purchased)
  end

  def thanked?
    thanked_at.present?
  end

  # The owner thanks whoever holds the reservation, once per reservation:
  # reserving or releasing clears the mark. The version from the button keeps
  # a late press from thanking someone who reserved after the card was shown.
  def thank_reserver!(expected_version: reservation_version)
    changed = self.class.where(id: id, reservation_version: expected_version, thanked_at: nil)
      .where.not(reserved_by: nil)
      .update_all(thanked_at: Time.current, updated_at: Time.current) == 1
    reload
    changed
  end

  private

  def change_reservation(previous_reserver, next_reserver, expected_version)
    changed = self.class.where(id: id, reserved_by: previous_reserver, reservation_version: expected_version)
      .update_all(reserved_by: next_reserver, reservation_version: expected_version + 1,
                  purchased_at: nil, thanked_at: nil, updated_at: Time.current) == 1

    reload
    changed
  end

  def url_opens_in_a_browser
    errors.add(:url, :invalid) unless web_uri
  end
end
