module Api
  class BatchesController < ApplicationController
    before_action :require_shop
    before_action :load_batch, except: [:index, :create]

    def index
      page = params[:page].to_i.clamp(1, 100_000)
      batches = current_shop.batches.order(id: :desc).offset((page - 1) * 25).limit(26).to_a
      counts = BatchOrder.where(batch_id: batches.map(&:id)).group(:batch_id, :status).count
      render json: { batches: batches.first(25).map { |batch|
        summary(batch, counts.filter_map { |(id, state), count| [state, count] if id == batch.id }.to_h)
      }, more: batches.size > 25 }
    end

    def show
      render_batch
    end

    def create
      file = params[:file]
      rows = BatchImport.read(file)
      @batch = BatchImport.new(current_shop, rows).save!(filename: file.original_filename, actor: actor)
      render_batch(:created)
    end

    def revise
      rows = params[:rows]
      if rows.is_a?(Array)
        rows = rows.map { |row| row.is_a?(ActionController::Parameters) ? row.to_unsafe_h : row }
      end
      @batch = BatchImport.new(current_shop, rows).save!(filename: @batch.filename, actor: actor, previous: @batch)
      render_batch(:created)
    end

    def confirm
      conflict = current_shop.with_lock do
        @batch.lock!
        next if @batch.confirmed_at
        if @batch.superseded_at || @batch.issues.any? || !@batch.orders.exists?
          raise BatchImport::Invalid, "Use a validated version with no errors."
        end

        duplicates = @batch.duplicate_references.sort
        acknowledged = params[:duplicate_references]
        acknowledged = acknowledged.sort if acknowledged.is_a?(Array) && acknowledged.all?(String)
        unless duplicates.empty? || acknowledged == duplicates
          next duplicates
        end

        @batch.update!(confirmed_at: Time.current)
        @batch.audit!("confirmed", actor: actor, duplicate_references: duplicates.size)
        nil
      end
      if conflict
        return render json: { error: "Review and acknowledge the duplicate orders.", duplicate_references: conflict },
                      status: :conflict
      end

      RunShopJob.perform_later(current_shop.id)
      render_batch
    end

    def pause
      set_paused(true)
    end

    def resume
      set_paused(false)
    end

    def export
      csv = CSV.generate do |file|
        file << %w[csv_row order_ref sku quantity batchcart_status shopify_draft_id shopify_draft_name shopify_status error]
        orders = @batch.orders.index_by(&:reference)
        @batch.rows.each_with_index do |row, index|
          order = orders[row.fetch("order_ref")]
          file << [
            index + 2, spreadsheet_cell(row.fetch("order_ref")), spreadsheet_cell(row.fetch("sku")),
            spreadsheet_cell(row.fetch("quantity")), order&.status || "invalid", order&.remote_id,
            spreadsheet_cell(order&.remote_name), order&.remote_status, order&.error_code
          ]
        end
      end
      response.headers["X-Content-Type-Options"] = "nosniff"
      send_data csv, filename: "batchcart-#{@batch.id}-results.csv", type: "text/csv; charset=utf-8"
    end

    private

    def load_batch
      @batch = current_shop.batches.find(params[:id])
    end

    def set_paused(paused)
      @batch.with_lock do
        raise BatchImport::Invalid, "Confirm the batch first." unless @batch.confirmed_at

        if @batch.paused_at.present? != paused
          @batch.update!(paused_at: paused ? Time.current : nil)
          @batch.audit!(paused ? "paused" : "resumed", actor: actor)
        end
      end
      RunShopJob.perform_later(current_shop.id) unless paused
      render_batch
    end

    def summary(batch, counts)
      {
        id: batch.id, filename: batch.filename, version: batch.version, created_at: batch.created_at,
        state: batch.state(counts), counts: counts, issues_count: batch.issues.size
      }
    end

    def render_batch(status = :ok)
      orders = @batch.orders.order(:id).to_a
      counts = orders.map(&:status).tally
      render json: summary(@batch, counts).merge(
        confirmed_at: @batch.confirmed_at, previous_id: @batch.previous_id, revision_id: @batch.revision&.id,
        rows: @batch.rows, issues: @batch.issues,
        duplicate_references: @batch.confirmed_at ? [] : @batch.duplicate_references(orders),
        orders: orders.map { |order| order.as_json(only: %i[
          id reference marker status attempts error_code remote_id remote_name remote_status
        ]).merge(order.request_data) },
        history: @batch.audit_events.order(id: :desc).limit(100).as_json(only: %i[
          batch_order_id action actor created_at details
        ])
      ), status: status
    end

    def spreadsheet_cell(value)
      value.to_s.match?(/\A[\s]*[=+@-]|\A[\r\n\t]/) ? "'#{value}" : value
    end
  end
end
