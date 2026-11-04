# Russian needs one/few/many forms; the rule lives in config/locales/plurals.rb
require "i18n/backend/pluralization"
I18n::Backend::Simple.include(I18n::Backend::Pluralization)
