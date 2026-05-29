# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module OracleEnhanced
      module CompatibilityStrategy # :nodoc: all
        extend ActiveRecord::Migration::Compatibility::AdapterStrategy

        class V8_1 < ActiveRecord::Migration::Compatibility::BaseStrategy
          def apply_create_table_options(_table_name, options)
            options[:identity] = false unless options.key?(:identity)
            options[:_implicit_unique_constraint] = true
          end

          def apply_add_index_options(_table_name, _column_name, options)
            options[:_implicit_unique_constraint] = true
          end
        end
      end
    end
  end
end
