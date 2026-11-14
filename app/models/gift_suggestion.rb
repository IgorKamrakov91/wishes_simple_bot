# One request for gift ideas for a list: the request, its result, the daily
# limit and the guard against adding the same idea twice. Only the list title
# and gift titles are sent to the model; nothing here is logged.
class GiftSuggestion < ApplicationRecord
  DAILY_LIMIT = 2
  GLOBAL_DAILY_LIMIT = 300
  STATUSES = %w[pending processing ready failed].freeze
  # A request stuck this long (lost job, crash during the call) counts as failed
  STALE_AFTER = 2.minutes
  # Old requests are kept a little longer than they can be opened, so a new
  # request for the same list can avoid repeating recent ideas
  KEEP_FOR = 3.days
  OPEN_FOR = 2.days
  MAX_PREVIOUS_IDEAS = 40
  TIME_ZONE = "Europe/Moscow"
  # Serializes the app-wide count across users (the user lock covers one person)
  GLOBAL_LOCK_KEY = 74_201_108

  Request = Struct.new(:status, :suggestion)

  belongs_to :user
  belongs_to :wishlist

  validates :status, inclusion: { in: STATUSES }

  scope :today, -> { where(created_at: Time.current.in_time_zone(TIME_ZONE).beginning_of_day..) }
  scope :unexpired, -> { where(created_at: OPEN_FOR.ago..) }
  scope :active, -> {
    where(status: %w[pending processing]).where("COALESCE(started_at, created_at) >= ?", STALE_AFTER.ago)
  }
  # Failures and timed-out jobs free the person's allowance for another try.
  scope :counted_for_personal_limit, -> { where(status: "ready").or(active) }

  def self.remaining_requests_for(user)
    (DAILY_LIMIT - where(user_id: user.id).today.counted_for_personal_limit.count).clamp(0, DAILY_LIMIT)
  end

  def self.latest_ready_for(user, wishlist)
    unexpired.where(user_id: user.id, wishlist_id: wishlist.id, status: "ready").order(id: :desc).first
  end

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
      active = where(user: user).active.order(:id).last
      next Request.new(:active, active) if active

      next Request.new(:user_limit) if remaining_requests_for(user).zero?

      # The cost bound still includes every request, even failed or stale ones.
      connection.execute("SELECT pg_advisory_xact_lock(#{GLOBAL_LOCK_KEY})")
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

  # Ideas already suggested for this list by the owner's earlier requests,
  # newest first
  def previous_titles
    self.class.where(user_id: user_id, wishlist_id: wishlist_id, status: "ready", created_at: KEEP_FOR.ago..)
      .where.not(id: id).order(id: :desc).flat_map(&:titles).uniq.first(MAX_PREVIOUS_IDEAS)
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
