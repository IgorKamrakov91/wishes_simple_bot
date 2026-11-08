# One request for gift ideas for a list: the request, its result, the daily
# limit and the guard against adding the same idea twice. Only the list title
# and gift titles are sent to the model; nothing here is logged.
class GiftSuggestion < ApplicationRecord
  DAILY_LIMIT = 2
  GLOBAL_DAILY_LIMIT = 300
  STATUSES = %w[pending processing ready failed].freeze
  # A request stuck this long (lost job, crash during the call) counts as failed
  STALE_AFTER = 2.minutes
  KEEP_FOR = 2.days
  TIME_ZONE = "Europe/Moscow"

  Request = Struct.new(:status, :suggestion)

  belongs_to :user
  belongs_to :wishlist

  validates :status, inclusion: { in: STATUSES }

  scope :today, -> { where(created_at: Time.current.in_time_zone(TIME_ZONE).beginning_of_day..) }

  def self.enabled?
    ENV["YANDEX_AI_API_KEY"].present? && ENV["YANDEX_AI_FOLDER_ID"].present? && ENV["YANDEX_AI_ENABLED"] != "false"
  end

  def self.global_daily_limit
    ENV.fetch("YANDEX_AI_DAILY_LIMIT", GLOBAL_DAILY_LIMIT).to_i
  end

  # Starts a request for the owner's list unless one is running or a limit is
  # reached. Checked and created under a lock on the user, so two quick
  # presses can't both pass the limit.
  def self.request_for!(user, wishlist)
    return Request.new(:disabled) unless enabled?
    raise ActiveRecord::RecordNotFound unless wishlist.user_id == user.id

    user.with_lock do
      active = where(user: user, status: %w[pending processing]).order(:id).last
      next Request.new(:active, active) if active && !active.stale?

      next Request.new(:user_limit) if where(user: user).today.count >= DAILY_LIMIT
      next Request.new(:global_limit) if today.count >= global_daily_limit

      suggestion = create!(user: user, wishlist: wishlist, locale: I18n.locale.to_s)
      ActiveRecord.after_all_transactions_commit { GiftIdeasJob.perform_later(suggestion.id) }
      Request.new(:created, suggestion)
    end
  end

  def stale?
    %w[pending processing].include?(status) && (started_at || created_at) < STALE_AFTER.ago
  end

  def ready?
    status == "ready"
  end

  def failed?
    status == "failed" || stale?
  end

  def titles
    ideas.map { |idea| idea["title"] }
  end

  # Moves a pending request to processing exactly once
  def claim!
    self.class.where(id: id, status: "pending").update_all(status: "processing", started_at: Time.current, updated_at: Time.current) == 1
  end

  def finish!(titles)
    update!(status: "ready", ideas: titles.map { |title| { "title" => title, "item_id" => nil } })
  end

  def fail!(code)
    update!(status: "failed", error_code: code.to_s.first(40))
  end

  # Adds idea number `index` to the list as a gift without a link. Repeated
  # presses and an idea already in the list give back the existing gift; a
  # deleted gift is not silently recreated.
  def add_idea!(user, index)
    return [ :unavailable, nil ] unless user_id == user.id && ready?

    with_lock do
      idea = ideas[index]
      next [ :unavailable, nil ] unless idea

      if idea["item_id"]
        item = wishlist.items.find_by(id: idea["item_id"])
        next item ? [ :already, item ] : [ :gone, nil ]
      end

      existing = wishlist.items.find { |gift| gift.title.to_s.strip.casecmp?(idea["title"].to_s.strip) }
      item = existing || wishlist.items.create!(title: idea["title"])
      update!(ideas: ideas.each_with_index.map { |entry, i| i == index ? idea.merge("item_id" => item.id) : entry })
      [ existing ? :already : :added, item ]
    end
  end
end
