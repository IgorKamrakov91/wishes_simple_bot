class AddOnboardingNudges < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :notify_onboarding, :boolean, default: true, null: false
    add_column :gift_suggestions, :system_generated, :boolean, default: false, null: false

    create_table :onboarding_nudges do |t|
      t.references :user, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.references :wishlist, foreign_key: { on_delete: :nullify }
      t.references :gift_suggestion, foreign_key: { on_delete: :nullify }
      t.string :locale, null: false
      t.json :ideas, default: [], null: false
      t.datetime :preparing_at
      t.datetime :prepared_at
      t.datetime :claimed_at
      t.datetime :retry_at
      t.datetime :sent_at
      t.integer :attempts, default: 0, null: false
      t.timestamps
    end
  end
end
