class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.bigint :telegram_id, null: false
      t.string :username
      t.string :first_name
      t.string :last_name
      t.datetime :last_seen_at

      t.timestamps
    end

    add_index :users, :telegram_id, unique: true
  end
end
