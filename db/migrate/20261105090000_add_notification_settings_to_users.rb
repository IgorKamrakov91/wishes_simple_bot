class AddNotificationSettingsToUsers < ActiveRecord::Migration[8.1]
  def change
    # Owners hear about reservations in their lists unless they turn it off;
    # guests hear about reservations in friends' lists only if they turn it on
    add_column :users, :notify_own_reservations, :boolean, default: true, null: false
    add_column :users, :notify_friend_reservations, :boolean, default: false, null: false
  end
end
