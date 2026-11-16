Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.force_ssl = true
  config.assume_ssl = true
  config.log_level = :info
  config.hosts = [URI.parse(ENV.fetch("APP_URL")).host]
end
