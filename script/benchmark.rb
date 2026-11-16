require "benchmark"
require "stringio"

abort "Run with RAILS_ENV=test and BATCHCART_DEMO=1." unless Rails.env.test? && ENV["BATCHCART_DEMO"] == "1"

size = Integer(ARGV.fetch(0, "500"), 10)
trials = Integer(ARGV.fetch(1, "3"), 10)
abort "Use 1–#{BatchImport::MAX_ROWS} orders and 1–20 trials." unless size.between?(1, BatchImport::MAX_ROWS) && trials.between?(1, 20)

shop = Shop.find_or_create_by!(domain: Shop::DEMO_DOMAIN)
prefix = SecureRandom.hex(4)
measurements = trials.times.map do |trial|
  csv = CSV.generate do |file|
    file << BatchImport::HEADERS
    size.times do |index|
      ref = "bench-#{prefix}-#{trial}-#{index}"
      file << [ref, "Taylor", "Sample", "#{ref}@example.test", "5 Sample Street", "", "Toronto", "ON", "CA",
               "M5V 2T6", "GIFT-MUG", "2"]
    end
  end
  batch = nil
  import_s = Benchmark.realtime do
    rows = BatchImport.read(StringIO.new(csv))
    batch = BatchImport.new(shop, rows).save!(filename: "benchmark.csv", actor: "benchmark")
    raise "Unexpected validation errors" unless batch.issues.empty? && batch.orders.count == size
  end
  batch.update!(confirmed_at: Time.current)
  create_s = Benchmark.realtime do
    (size / 10.0).ceil.times { RunShopJob.perform_now(shop.id) }
  end
  raise "The worker did not finish" unless batch.orders.where(status: "succeeded").count == size

  { import_ms: (import_s * 1_000).round(1), create_ms: (create_s * 1_000).round(1) }
end

median = lambda do |items|
  sorted = items.sort
  middle = sorted.length / 2
  sorted.length.odd? ? sorted[middle] : ((sorted[middle - 1] + sorted[middle]) / 2).round(1)
end
puts JSON.pretty_generate(
  orders: size, trials: measurements, median_import_ms: median.call(measurements.pluck(:import_ms)),
  median_create_ms: median.call(measurements.pluck(:create_ms))
)
