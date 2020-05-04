# The MIT License (MIT)
#
# Copyright (c) 2020 Google LLC.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# ITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

# The MIT License (MIT)
#
# Copyright (c) 2020 Google LLC.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# ITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

# frozen_string_literal: true

require "active_record/connection_adapters/spanner/schema_creation"
require "active_record/connection_adapters/spanner/schema_dumper"

module ActiveRecord
  module ConnectionAdapters
    module Spanner
      #
      # # SchemaStatements
      #
      # Collection of methods to handle database schema.
      #
      # [Schema Doc](https://cloud.google.com/spanner/docs/information-schema)
      #
      module SchemaStatements
        def current_database
          @connection.database_id
        end

        # Table

        def data_sources
          information_schema { |i| i.tables.map(&:name) }
        end
        alias tables data_sources

        def table_exists? table_name
          information_schema { |i| i.table table_name }.present?
        end
        alias data_source_exists? table_exists?

        def create_table table_name, **options
          td = create_table_definition table_name, options

          if options[:id] != false
            pk = options.fetch :primary_key do
              Base.get_primary_key table_name.to_s.singularize
            end

            if pk.is_a? Array
              td.primary_keys pk
            else
              td.primary_key pk, options.fetch(:id, :primary_key), {}
            end
          end

          yield td if block_given?

          statements = []

          if options[:force]
            statements.concat drop_table_with_indexes_sql(table_name, options)
          end

          statements << schema_creation.accept(td)

          td.indexes.each do |column_name, index_options|
            id = create_index_definition table_name, column_name, index_options
            statements << schema_creation.accept(id)
          end

          with_batching = ![
            ActiveRecord::InternalMetadata.table_name,
            ActiveRecord::SchemaMigration.table_name
          ].include?(table_name.to_s)

          execute_schema_statements statements, with_batching: with_batching
        end

        def drop_table table_name, options = {}
          statements = drop_table_with_indexes_sql table_name, options
          execute_schema_statements statements
        end

        def create_join_table table_1, table_2, column_options: {}, **options
          return super unless block_given?

          super do |td|
            yield td
            td.primary_key :id unless td.columns.any?(&:primary_key?)
          end
        end

        def rename_table _table_name, _new_name
          raise ActiveRecordSpannerAdapter::NotSupportedError, \
                "rename_table is not implemented"
        end

        # Column

        def column_definitions table_name
          information_schema { |i| i.table_columns table_name }
        end

        def new_column_from_field _table_name, field
          ConnectionAdapters::Column.new \
            field.name,
            field.default,
            fetch_type_metadata(field.spanner_type, field.ordinal_position),
            field.nullable
        end

        def fetch_type_metadata sql_type, ordinal_position = nil
          Spanner::TypeMetadata.new \
            super(sql_type), ordinal_position: ordinal_position
        end

        def add_column table_name, column_name, type, **options
          # Add column with NOT NULL not supported by spanner.
          # It is currenlty un-implemented state in spanner service.
          nullable = options.delete(:null) == false

          at = create_alter_table table_name
          at.add_column column_name, type, options

          statements = [schema_creation.accept(at)]

          # Alter NOT NULL
          if nullable
            cd = at.adds.first.column
            cd.null = false
            ccd = Spanner::ChangeColumnDefinition.new(
              table_name, cd, column_name
            )
            statements << schema_creation.accept(ccd)
          end

          execute_schema_statements statements
        end

        def remove_column table_name, column_name, _type = nil, _options = {}
          statements = drop_column_sql table_name, column_name
          execute_schema_statements statements
        end

        def remove_columns table_name, *column_names
          if column_names.empty?
            raise ArgumentError, "You must specify at least one column name. "\
              "Example: remove_columns(:people, :first_name)"
          end

          statements = []

          column_names.each do |column_name|
            statements.concat drop_column_sql(table_name, column_name)
          end

          execute_schema_statements statements
        end

        def change_column table_name, column_name, type, options = {}
          column = information_schema do |i|
            i.table_column table_name, column_name
          end

          unless column
            raise ArgumentError,
                  "Column '#{column_name}' not exist for table '#{table_name}'"
          end

          indexes = information_schema do |i|
            i.indexes_by_columns table_name, column_name
          end

          statements = indexes.map do |index|
            schema_creation.accept DropIndexDefinition.new(index.name)
          end

          column = new_column_from_field table_name, column

          type ||= column.type
          options[:null] = column.null unless options.key? :null

          if ["STRING", "BYTES"].include? type
            options[:limit] = column.limit unless options.key? :limit
          end

          # Only timestamp type can set commit timestamp
          if type == "TIMESTAMP" &&
             options.key?(:allow_commit_timestamp) == false
            options[:allow_commit_timestamp] = column.allow_commit_timestamp
          end

          td = create_table_definition table_name
          cd = td.new_column_definition column.name, type, options

          ccd = Spanner::ChangeColumnDefinition.new table_name, cd, column.name
          statements << schema_creation.accept(ccd)

          # Recreate indexes
          indexes.each do |index|
            id = create_index_definition(
              table_name,
              index.column_names,
              index.options
            )
            statements << schema_creation.accept(id)
          end

          execute_schema_statements statements
        end

        def change_column_null table_name, column_name, null, _default = nil
          change_column table_name, column_name, nil, null: null
        end

        def change_column_default _table_name, _column_name, _default_or_changes
          raise ActiveRecordSpannerAdapter::NotSupportedError, \
                "change column with default value not supported."
        end

        def rename_column table_name, column_name, new_column_name
          column = information_schema do |i|
            i.table_column table_name, column_name
          end

          unless column
            raise ArgumentError,
                  "Column '#{column_name}' not exist for table '#{table_name}'"
          end

          # Add Column
          cast_type = lookup_cast_type column.spanner_type
          add_column table_name, new_column_name, cast_type.type, column.options

          # Copy data
          sql = "UPDATE %{table} SET %{new_name} = %{old_name} WHERE true"
          values = {
            table: table_name,
            new_name: quote_column_name(new_column_name),
            old_name: quote_column_name(column_name)
          }

          execute sql % values

          # Recreate Indexes
          indexes = information_schema.indexes_by_columns(
            table_name, column_name
          )
          indexes.each do |index|
            remove_index table_name, name: index.name
            options = index.rename_column_options column_name, new_column_name
            options[:options][:name] = options[:options][:name].to_s.gsub(
              column_name.to_s, new_column_name.to_s
            )
            add_index table_name, options[:columns], options[:options]
          end

          # Recreate Foreign keys
          fkeys = foreign_keys table_name, column: column_name

          fkeys.each do |fk|
            remove_foreign_key table_name, name: fk.name
            options = fk.options.except :column, :name
            options[:column] = new_column_name
            add_foreign_key table_name, fk.to_table, options
          end

          # Drop Indexes, Drop Foreign keys and colums
          remove_column table_name, column_name
        end

        # Index

        def indexes table_name
          result = information_schema do |i|
            i.indexes table_name, index_type: "INDEX"
          end

          result.map do |index|
            IndexDefinition.new(
              index.table,
              index.name,
              index.columns.map(&:name),
              unique: index.unique,
              null_filtered: index.null_filtered,
              interleve_in: index.interleve_in,
              storing: index.storing,
              orders: index.orders
            )
          end
        end

        def index_name_exists? table_name, index_name
          information_schema { |i| i.index table_name, index_name }.present?
        end

        def add_index table_name, column_name, options = {}
          id = create_index_definition table_name, column_name, options

          if data_source_exists?(table_name) &&
             index_name_exists?(table_name, id.name)
            raise ArgumentError, "Index name '#{id.name}' on table" \
                                 "'#{table_name}' already exists"
          end

          execute_schema_statements schema_creation.accept(id)
        end

        def remove_index table_name, options = {}
          index_name = index_name_for_remove table_name, options
          statement = schema_creation.accept(
            DropIndexDefinition.new(index_name)
          )
          execute_schema_statements statement
        end

        def rename_index table_name, old_name, new_name
          validate_index_length! table_name, new_name

          old_index = information_schema { |i| i.index table_name, old_name }
          return unless old_index

          statements = [
            schema_creation.accept(DropIndexDefinition.new(old_name))
          ]

          id = IndexDefinition.new \
            old_index.table,
            new_name,
            old_index.columns.map(&:name),
            unique: old_index.unique,
            null_filtered: old_index.null_filtered,
            interleve_in: old_index.interleve_in,
            storing: old_index.storing,
            orders: old_index.orders

          statements << schema_creation.accept(id)
          execute_schema_statements statements
        end

        # Primary Keys

        def primary_keys table_name
          columns = information_schema do |i|
            i.table_primary_keys table_name
          end

          columns.map(&:name)
        end

        # Foreign Keys

        def foreign_keys table_name, column: nil
          raise ArgumentError if table_name.blank?

          result = information_schema { |i| i.foreign_keys table_name }

          if column
            result = result.select { |fk| fk.columns.include? column.to_s }
          end

          result.map do |fk|
            options = {
              column: fk.columns.first,
              name: fk.name,
              primary_key: fk.ref_columns.first,
              on_delete: fk.on_update,
              on_update: fk.on_update
            }

            ForeignKeyDefinition.new table_name, fk.ref_table, options
          end
        end

        def add_foreign_key from_table, to_table, options = {}
          options = foreign_key_options from_table, to_table, options
          at = create_alter_table from_table
          at.add_foreign_key to_table, options

          execute_schema_statements schema_creation.accept(at)
        end

        def remove_foreign_key from_table, to_table = nil, **options
          fk_name_to_delete = foreign_key_for!(
            from_table, to_table: to_table, **options
          ).name

          at = create_alter_table from_table
          at.drop_foreign_key fk_name_to_delete

          execute_schema_statements schema_creation.accept(at)
        end

        # Reference Column

        def add_reference table_name, ref_name, **options
          ReferenceDefinition.new(ref_name, options).add_to(
            update_table_definition(table_name, self)
          )
        end
        alias add_belongs_to add_reference

        def quoted_scope name = nil, type: nil
          scope = { schema: quote("") }
          scope[:name] = quote name if name
          scope[:type] = quote type if type
          scope
        end

        def create_schema_dumper options
          SchemaDumper.create self, options
        end

        def type_to_sql type, limit: nil, precision: nil, scale: nil, **_opts
          type = type.to_sym if type
          native = native_database_types[type]

          return type.to_s unless native

          sql_type = (native.is_a?(Hash) ? native[:name] : native).dup

          if [:string, :text, :binary].include? type
            return "#{sql_type}(#{limit || native[:limit]})"
          end

          sql_type
        end

        private

        def schema_creation
          SchemaCreation.new self
        end

        def create_table_definition *args
          TableDefinition.new self, *args
        end

        def create_index_definition table_name, column_name, **options
          column_names = index_column_names column_name

          options.assert_valid_keys(
            :unique, :order, :name, :where, :length, :internal, :using,
            :algorithm, :type, :opclass, :interleve_in, :storing,
            :null_filtered
          )

          index_name = options[:name].to_s if options.key? :name
          index_name ||= index_name table_name, column_names

          validate_index_length! table_name, index_name

          IndexDefinition.new \
            table_name,
            index_name,
            column_names,
            unique: options[:unique],
            null_filtered: options[:null_filtered],
            interleve_in: options[:interleve_in],
            storing: options[:storing],
            orders: options[:order]
        end

        def drop_table_with_indexes_sql table_name, options
          statements = []

          table = information_schema { |i| i.table table_name, view: :indexes }
          return statements unless table

          table.indexes.each do |index|
            next if index.primary?

            statements << schema_creation.accept(
              DropIndexDefinition.new(index.name)
            )
          end

          statements << schema_creation.accept(
            DropTableDefinition.new(table_name, options)
          )
          statements
        end

        def drop_column_sql table_name, column_name
          indexes = information_schema do |i|
            i.indexes_by_columns table_name, column_name
          end

          statements = indexes.map do |index|
            schema_creation.accept DropIndexDefinition.new(index.name)
          end

          foreign_keys(table_name, column: column_name).each do |fk|
            at = create_alter_table table_name
            at.drop_foreign_key fk.name
            statements << schema_creation.accept(at)
          end

          statements << schema_creation.accept(
            DropColumnDefinition.new(table_name, column_name)
          )

          statements
        end

        def execute_schema_statements statements, with_batching: true
          if disabled_ddl_batching? || !with_batching
            return execute_ddl statements
          end

          Array(statements).each { |s| execute s }
        end

        def information_schema
          info_scheam = \
            ActiveRecordSpannerAdapter::Connection.information_schema @config

          return info_scheam unless block_given?

          execute_pending_ddl
          yield info_scheam
        end
      end
    end
  end
end
