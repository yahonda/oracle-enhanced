# frozen_string_literal: true

require "timeout"

describe "_exec_insert prepared-statement cache gating" do
  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection
    @conn.create_table :test_exec_insert_caching, force: true, id: false do |t|
      t.integer :id, null: false
      t.string :name
    end
    @conn.execute "CREATE SEQUENCE test_exec_insert_caching_seq"
  end

  after(:all) do
    @conn.execute "BEGIN EXECUTE IMMEDIATE 'DROP SEQUENCE test_exec_insert_caching_seq'; EXCEPTION WHEN OTHERS THEN NULL; END;"
    @conn.drop_table :test_exec_insert_caching, if_exists: true
  end

  # The deadlock this regression guards against requires both the default
  # cursor_sharing=force *and* an amd64 Oracle Database server; under :exact
  # or against an arm64 server image the spec would silently pass without
  # exercising the regression. See #2619.
  it "does not deadlock when the same raw SQL connection.insert with RETURNING is issued twice" do
    sql = "INSERT INTO test_exec_insert_caching (id, name) VALUES (test_exec_insert_caching_seq.NEXTVAL, 'alpha')"
    Timeout.timeout(5) do
      @conn.insert(sql, nil, "id")
      @conn.insert(sql, nil, "id")
    end
    expect(@conn.select_value("SELECT COUNT(*) FROM test_exec_insert_caching")).to eq(2)
  end
end
