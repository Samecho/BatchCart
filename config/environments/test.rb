Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = false
  config.consider_all_requests_local = true
  config.log_level = :warn
  config.active_job.queue_adapter = :test
  config.active_record.maintain_test_schema = false
  config.action_controller.allow_forgery_protection = false
end
