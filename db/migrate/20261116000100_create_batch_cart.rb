class CreateBatchCart < ActiveRecord::Migration[8.1]
  def change
    create_table :shops do |t|
      t.string :domain, null: false
      t.text :access_token
      t.text :refresh_token
      t.datetime :token_expires_at
      t.datetime :connected_at
      t.datetime :api_available_at
      t.integer :session_version, default: 0, null: false
      t.timestamps
    end
    add_index :shops, :domain, unique: true

    create_table :batches do |t|
      t.references :shop, null: false, foreign_key: true
      t.bigint :previous_id
      t.string :filename, null: false
      t.integer :version, null: false
      t.text :rows, null: false
      t.jsonb :issues, default: [], null: false
      t.datetime :confirmed_at
      t.datetime :paused_at
      t.datetime :superseded_at
      t.timestamps
    end
    add_index :batches, [:shop_id, :id], unique: true
    add_index :batches, :previous_id, unique: true
    add_foreign_key :batches, :batches, column: [:shop_id, :previous_id], primary_key: [:shop_id, :id]
    add_check_constraint :batches, "confirmed_at IS NULL OR superseded_at IS NULL", name: "confirmed_batches_stay_current"
    add_check_constraint :batches, "paused_at IS NULL OR confirmed_at IS NOT NULL", name: "only_confirmed_batches_pause"

    create_table :batch_orders do |t|
      t.references :batch, null: false, foreign_key: true
      t.string :reference, null: false
      t.string :marker, null: false
      t.string :fingerprint, null: false
      t.text :request_data, null: false
      t.string :status, default: "pending", null: false
      t.integer :attempts, default: 0, null: false
      t.integer :throttle_count, default: 0, null: false
      t.datetime :started_at
      t.datetime :next_attempt_at
      t.datetime :sync_at
      t.string :error_code
      t.string :remote_id
      t.string :remote_name
      t.string :remote_status
      t.datetime :remote_updated_at
      t.timestamps
    end
    add_index :batch_orders, [:batch_id, :reference], unique: true
    add_index :batch_orders, [:batch_id, :status, :next_attempt_at]
    add_index :batch_orders, :marker, unique: true
    add_index :batch_orders, :fingerprint
    add_index :batch_orders, :remote_id, unique: true
    add_index :batch_orders, [:sync_at, :id], where: "sync_at IS NOT NULL"
    add_check_constraint :batch_orders, "status IN ('pending','running','succeeded','failed','review','closed')", name: "batch_order_status"
    add_check_constraint :batch_orders, "(status = 'succeeded') = (remote_id IS NOT NULL)", name: "successful_order_has_remote_id"
    add_check_constraint :batch_orders, "status <> 'running' OR started_at IS NOT NULL", name: "running_order_has_start"

    create_table :audit_events do |t|
      t.references :batch, null: false, foreign_key: true
      t.bigint :batch_order_id
      t.string :actor, null: false
      t.string :action, null: false
      t.jsonb :details, default: {}, null: false
      t.datetime :created_at, null: false
    end
    add_index :batch_orders, [:batch_id, :id], unique: true
    add_foreign_key :audit_events, :batch_orders, column: [:batch_id, :batch_order_id], primary_key: [:batch_id, :id]

    create_table :webhook_deliveries do |t|
      t.references :shop, null: false, foreign_key: true
      t.string :delivery_id, null: false
      t.string :topic, null: false
      t.datetime :created_at, null: false
    end
    add_index :webhook_deliveries, [:shop_id, :delivery_id], unique: true

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION protect_batch_snapshot() RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF ROW(NEW.shop_id, NEW.previous_id, NEW.filename, NEW.version, NEW.rows, NEW.issues)
              IS DISTINCT FROM ROW(OLD.shop_id, OLD.previous_id, OLD.filename, OLD.version, OLD.rows, OLD.issues)
              OR (OLD.confirmed_at IS NOT NULL AND NEW.confirmed_at IS DISTINCT FROM OLD.confirmed_at)
              OR (OLD.superseded_at IS NOT NULL AND NEW.superseded_at IS DISTINCT FROM OLD.superseded_at) THEN
              RAISE EXCEPTION 'Batch snapshots cannot be edited';
            END IF;
            RETURN NEW;
          END $$;
          CREATE TRIGGER batch_snapshot BEFORE UPDATE ON batches
          FOR EACH ROW EXECUTE FUNCTION protect_batch_snapshot();

          CREATE FUNCTION protect_order_snapshot() RETURNS trigger LANGUAGE plpgsql AS $$
          DECLARE parent_confirmed_at timestamp;
          BEGIN
            IF TG_OP = 'UPDATE' THEN
              IF ROW(NEW.batch_id, NEW.reference, NEW.marker, NEW.fingerprint, NEW.request_data)
                IS DISTINCT FROM ROW(OLD.batch_id, OLD.reference, OLD.marker, OLD.fingerprint, OLD.request_data) THEN
                RAISE EXCEPTION 'Order snapshots cannot be edited';
              END IF;
              RETURN NEW;
            END IF;
            IF TG_OP = 'DELETE' THEN
              SELECT confirmed_at INTO parent_confirmed_at FROM batches WHERE id = OLD.batch_id FOR UPDATE;
              IF parent_confirmed_at IS NOT NULL THEN
                RAISE EXCEPTION 'Confirmed order snapshots cannot be deleted';
              END IF;
              RETURN OLD;
            END IF;
            SELECT confirmed_at INTO parent_confirmed_at FROM batches WHERE id = NEW.batch_id FOR UPDATE;
            IF parent_confirmed_at IS NOT NULL THEN
              RAISE EXCEPTION 'Confirmed batches cannot accept new order snapshots';
            END IF;
            RETURN NEW;
          END $$;
          CREATE TRIGGER order_snapshot BEFORE INSERT OR UPDATE OR DELETE ON batch_orders
          FOR EACH ROW EXECUTE FUNCTION protect_order_snapshot();
        SQL
      end
      direction.down do
        execute <<~SQL
          DROP TRIGGER order_snapshot ON batch_orders;
          DROP FUNCTION protect_order_snapshot();
          DROP TRIGGER batch_snapshot ON batches;
          DROP FUNCTION protect_batch_snapshot();
        SQL
      end
    end
  end
end
