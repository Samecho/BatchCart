require_relative "boot"
require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "solid_queue"
Bundler.require(*Rails.groups)

module BatchCart
  class Application < Rails::Application
    config.load_defaults 8.1
    config.active_job.queue_adapter = :solid_queue
    config.active_job.verbose_enqueue_logs = false
    config.active_job.log_arguments = false
    config.active_record.schema_format = :sql
    config.active_record.dump_schema_after_migration = false
    config.public_file_server.enabled = true
    config.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new($stdout))
    config.log_tags = [:request_id]
    config.action_controller.action_on_unpermitted_parameters = false
    config.action_dispatch.tld_length = 1
    config.session_store :cookie_store, key: "_batchcart", httponly: true,
                         same_site: :lax, secure: ENV["APP_URL"].to_s.start_with?("https://"),
                         expire_after: 8.hours
    config.filter_parameters += [
      :code, :hmac, :state, :host, :rows, :file, :email, :address,
      :first_name, :last_name, :token, :secret, :customer, :phone, :note, :line_items
    ]
  end
end
