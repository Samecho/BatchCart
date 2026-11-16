Rails.application.configure do
  config.enable_reloading = true
  config.eager_load = false
  config.consider_all_requests_local = false
  config.log_level = :info
  config.hosts << "web" if ENV["BATCHCART_DEMO"] == "1"
  config.hosts << URI.parse(ENV["APP_URL"]).host if ENV["APP_URL"].present?
end
