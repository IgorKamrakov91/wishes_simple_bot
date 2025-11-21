class User < ApplicationRecord
  has_many :wishlists, dependent: :destroy
  has_many :list_viewers, dependent: :destroy

  validates :telegram_id, presence: true, uniqueness: true

  def self.find_or_create_from_telegram(data)
    find_or_initialize_by(telegram_id: data[:id]).tap do |user|
      user.assign_attributes(
        username: data[:username],
        first_name: data[:first_name],
        last_name: data[:last_name],
        last_seen_at: Time.current
      )
      user.save!
    end
  end
end