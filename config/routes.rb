Rails.application.routes.draw do
  # Health check for kamal-proxy.
  get "up" => "rails/health#show", as: :rails_health_check

  post "/telegram/webhook", to: "telegram#webhook"
end
