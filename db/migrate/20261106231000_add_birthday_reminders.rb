class AddBirthdayReminders < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :notify_birthdays, :boolean, default: true, null: false
    add_column :users, :birthdate_day, :integer
    add_column :users, :birthdate_month, :integer
    add_column :users, :birthdate_checked_at, :datetime
    add_column :users, :birthdate_synced_at, :datetime

    create_table :birthday_reminder_deliveries do |t|
      t.references :recipient, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.references :owner, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      # Year of the upcoming birthday, not the year of the send or of birth.
      t.integer :birthday_year, null: false
      t.integer :attempts, null: false, default: 0
      t.datetime :claimed_at
      t.datetime :retry_at
      t.datetime :sent_at
      t.timestamps
      t.index [ :recipient_id, :owner_id, :birthday_year ], unique: true, name: "index_birthday_reminders_on_recipient_owner_year"
    end
  end
end
