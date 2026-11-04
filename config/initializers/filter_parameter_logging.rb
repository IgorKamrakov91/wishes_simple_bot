# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc
]

# Telegram updates: what people write (gift names, links, /start l_<token>
# invitations, inline queries) and who they are stay out of the logs.
# Exact key names, so ids, chat types and callback data stay visible.
Rails.application.config.filter_parameters += [
  /\A(text|caption|query|first_name|last_name|username|phone_number|title|description)\z/
]
