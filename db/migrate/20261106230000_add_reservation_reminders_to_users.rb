class AddReservationRemindersToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :reservation_reminder_days, :integer, default: 0, null: false
    add_column :users, :reservation_reminder_next_at, :datetime
    add_column :users, :reservation_reminder_last_attempt_at, :datetime
    add_column :users, :reservation_reminder_last_sent_at, :datetime
    add_index :users, :reservation_reminder_next_at
    add_check_constraint :users, "reservation_reminder_days IN (0, 7, 14, 30)",
                         name: "users_reservation_reminder_days"
  end
end
