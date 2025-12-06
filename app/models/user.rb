class User < ApplicationRecord
  has_many :wishlists, dependent: :destroy
  has_many :list_viewers, dependent: :destroy
  has_many :viewed_wishlists, through: :list_viewers, source: :wishlist

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

  def start_creating_list!
    update!(bot_state: "creating_list", bot_payload: {})
  end

  def start_renaming_list!(wishlist_id:)
    update!(bot_state: "renaming_list", bot_payload: { wishlist_id: wishlist_id })
  end

  def start_adding_item!(wishlist_id:)
    update!(bot_state: "adding_item", bot_payload: { wishlist_id: wishlist_id })
  end

  def clear_state!
    update!(bot_state: nil, bot_payload: nil)
  end

  def full_name
    full_name = [ first_name, last_name ].map(&:presence).compact.join(" ")
    full_name.presence || username.presence || "Anonymous"
  end
end
