require "csv"

class BatchImport
  HEADERS = %w[order_ref first_name last_name email address1 address2 city province_code country_code zip sku quantity].freeze
  MAX_ROWS = 1_500
  MAX_BYTES = 1.megabyte
  SKU = /\A[a-zA-Z0-9_.\/-]{1,100}\z/
  ADDRESS = {
    "first_name" => "firstName", "last_name" => "lastName", "address1" => "address1", "address2" => "address2",
    "city" => "city", "province_code" => "provinceCode", "country_code" => "countryCode", "zip" => "zip"
  }.freeze
  RECIPIENT = (ADDRESS.keys + ["email"]).freeze
  OPTIONAL = %w[address2 province_code].freeze
  COUNTRIES = %w[
    AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV
    BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET
    FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM
    IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD
    ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE
    PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST
    SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS
    XK YE YT ZA ZM ZW
  ].freeze

  class Invalid < StandardError; end

  def self.read(file)
    raise Invalid, "Choose a CSV file." unless file.respond_to?(:read)
    raise Invalid, "The CSV must be at most 1 MB." if file.size > MAX_BYTES

    input = file.read(MAX_BYTES + 1).to_s.force_encoding(Encoding::UTF_8).delete_prefix("\uFEFF")
    raise Invalid, "Save the CSV as UTF-8 and upload it again." unless input.valid_encoding?

    rows = CSV.parse(input, field_size_limit: 4_096)
    header = rows.shift&.map { |field| field.to_s.strip }
    unless header && header.size == HEADERS.size && header.sort == HEADERS.sort
      raise Invalid, "The CSV headers must match the template."
    end
    rows.map.with_index(2) do |values, number|
      raise Invalid, "CSV record #{number} must have #{HEADERS.size} columns." unless values.size == header.size

      header.zip(values).to_h
    end
  rescue CSV::MalformedCSVError => error
    raise Invalid, "The CSV could not be read near record #{error.line_number}. Check the quotes and separators."
  end

  def initialize(shop, rows)
    @shop = shop
    unless rows.is_a?(Array) && rows.size.between?(1, MAX_ROWS)
      raise Invalid, "Use between 1 and #{MAX_ROWS} data records per batch."
    end

    @rows = rows.map do |row|
      raise Invalid, "Invalid CSV record." unless row.respond_to?(:keys) && (row.keys - HEADERS).empty?

      HEADERS.to_h do |field|
        value = row[field]
        unless value.nil? || (value.is_a?(String) && value.bytesize <= 4_096 && !value.include?("\0"))
          raise Invalid, "A field is too long or contains an invalid character."
        end
        [field, value.to_s.strip]
      end
    end
    @issues = []
  end

  def save!(filename:, actor:, previous: nil)
    entries = validate
    @shop.with_lock do
      previous&.reload
      raise Invalid, "Open the latest version before editing." if previous&.revision

      batch = @shop.batches.create!(
        filename: filename.to_s.tr("\\", "/").split("/").last.to_s.strip.first(120).presence || "orders.csv",
        version: previous ? previous.version + 1 : 1, previous: previous, rows: @rows, issues: @issues
      )
      batch.orders.insert_all!(entries) if entries.any?
      batch.audit!("validated", actor: actor, rows: @rows.size, valid_orders: entries.size, issues: @issues.size)
      if previous && !previous.confirmed_at
        previous.update!(superseded_at: Time.current)
        previous.audit!("superseded", actor: actor, revision_id: batch.id)
      end
      batch
    end
  end

  private

  def validate
    indexed_rows = @rows.each_with_index.map { |row, index| [row, index + 2] }
    skus = @rows.pluck("sku").uniq.select { |sku| SKU.match?(sku) }
    variants = skus.empty? ? {} : @shop.with_api_lock { @shop.api.variants(skus) }
    raise Invalid, "The shop is busy. Run validation again in a moment." unless variants

    indexed_rows.group_by { |row, _number| row.fetch("order_ref") }.filter_map do |reference, records|
      issue_count = @issues.size
      recipient = records.first.first.slice(*RECIPIENT)
      seen = Set.new
      items = records.filter_map do |row, number|
        validate_fields(row, number)
        RECIPIENT.each do |field|
          flag(number, field, "Must match the first line for this order.") if row[field] != recipient[field]
        end
        sku = row["sku"]
        flag(number, "sku", "This SKU already appears in the order. Combine the quantities.") if sku.present? && !seen.add?(sku)
        next unless SKU.match?(sku)

        matches = variants.fetch(sku, [])
        flag(number, "sku", "SKU was not found in Shopify.") if matches.empty?
        flag(number, "sku", "More than one Shopify variant has this SKU.") if matches.size > 1
        next unless matches.one?

        matches.first.merge("sku" => sku, "quantity" => row["quantity"].to_i, "row" => number)
      end
      flag(records.first.last, "order_ref", "Use at most 250 product lines per order.") if records.size > 250
      next unless issue_count == @issues.size

      address = ADDRESS.to_h { |field, key| [key, recipient.fetch(field)] }.compact_blank
      items_for_hash = items.map { |item| item.values_at("id", "quantity") }.sort
      digest_input = [@shop.id, recipient.values.map(&:downcase), items_for_hash]
      {
        reference: reference, marker: "bc-#{SecureRandom.uuid}",
        fingerprint: OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, JSON.generate(digest_input)),
        request_data: { "email" => recipient.fetch("email"), "address" => address, "items" => items }
      }
    end
  end

  def validate_fields(row, number)
    HEADERS.each do |field|
      value = row.fetch(field)
      if value.empty? && !OPTIONAL.include?(field)
        flag(number, field, "Required.")
      elsif value.size > 255 || value.match?(/[[:cntrl:]]/)
        flag(number, field, "Use at most 255 characters on one line.")
      end
    end
    flag(number, "sku", "Use letters, digits, dashes, underscores, dots or slashes.") if row["sku"].present? && !SKU.match?(row["sku"])
    if row["quantity"].present? && (!/\A[0-9]{1,4}\z/.match?(row["quantity"]) || !row["quantity"].to_i.between?(1, 9999))
      flag(number, "quantity", "Use a whole number from 1 to 9999.")
    end
    if row["email"].present? && !URI::MailTo::EMAIL_REGEXP.match?(row["email"])
      flag(number, "email", "Enter a valid email address.")
    end
    if row["country_code"].present? && !COUNTRIES.include?(row["country_code"])
      flag(number, "country_code", "Use a two-letter uppercase country code, such as CA.")
    end
    if row["province_code"].blank? && row["country_code"].in?(%w[CA US])
      flag(number, "province_code", "Enter the province or state code for this country.")
    end
  end

  def flag(row, field, message)
    @issues << { row: row, field: field, message: message }
  end
end
