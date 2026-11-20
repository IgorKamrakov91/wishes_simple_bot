namespace :onboarding do
  desc "Reset only funnel fields for one required Telegram user ID (keeps lists, gifts and input)"
  task :reset, [ :telegram_id ] => :environment do |_task, args|
    id = args[:telegram_id].to_s
    abort "Usage: bin/rails 'onboarding:reset[telegram_id]' (positive Telegram user ID required)" unless id.match?(/\A[1-9]\d*\z/)

    user = User.find_by(telegram_id: id)
    abort "No user with Telegram ID #{id}" unless user

    before, after = user.reset_onboarding!
    puts "Telegram ID: #{user.telegram_id} (user #{user.id})"
    puts "Before: #{before.to_json}"
    puts "After:  #{after.to_json}"
  end
end
