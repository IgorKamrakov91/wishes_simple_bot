Rails.application.routes.draw do
  post "/telegram/webhook", to: "telegram#webhook"
end
