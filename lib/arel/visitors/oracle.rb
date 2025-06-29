# frozen_string_literal: true

require_relative "oracle_common"

module Arel # :nodoc: all
  module Visitors
    class Oracle < Arel::Visitors::ToSql
      include OracleCommon

      private
        def visit_Arel_Nodes_SelectStatement(o, collector)
          o = order_hacks(o)

          # if need to select first records without ORDER BY and GROUP BY and without DISTINCT
          # then can use simple ROWNUM in WHERE clause
          if o.limit && o.orders.empty? && o.cores.first.groups.empty? && !o.offset && !o.cores.first.set_quantifier.class.to_s.match?(/Distinct/)
            o.cores.last.wheres.push Nodes::LessThanOrEqual.new(
              Nodes::SqlLiteral.new("ROWNUM"), o.limit.expr
            )
            return super
          end

          if o.limit && o.offset
            o        = o.dup
            limit    = o.limit.expr
            offset   = o.offset
            o.offset = nil
            collector << "
                SELECT * FROM (
                  SELECT raw_sql_.*, rownum raw_rnum_
                  FROM ("

            collector = super(o, collector)

            if offset.expr.type.is_a? ActiveModel::Type::Value
              collector << ") raw_sql_ WHERE rownum <= ("
              collector = visit offset.expr, collector
              collector << " + "
              collector = visit limit, collector
              collector << ") ) WHERE raw_rnum_ > "
              collector = visit offset.expr, collector
              return collector
            else
              collector << ") raw_sql_
                  WHERE rownum <= #{offset.expr.value_before_type_cast + limit.value_before_type_cast}
                )
                WHERE "
              return visit(offset, collector)
            end
          end

          if o.limit
            o       = o.dup
            limit   = o.limit.expr
            collector << "SELECT * FROM ("
            collector = super(o, collector)
            collector << ") WHERE ROWNUM <= "
            return visit limit, collector
          end

          if o.offset
            o        = o.dup
            offset   = o.offset
            o.offset = nil
            collector << "SELECT * FROM (
                  SELECT raw_sql_.*, rownum raw_rnum_
                  FROM ("
            collector = super(o, collector)
            collector << ") raw_sql_
                )
                WHERE "
            return visit offset, collector
          end

          super
        end

        def visit_Arel_Nodes_Limit(o, collector)
          collector
        end

        def visit_Arel_Nodes_Offset(o, collector)
          collector << "raw_rnum_ > "
          visit o.expr, collector
        end

        def visit_Arel_Nodes_Except(o, collector)
          collector << "( "
          collector = infix_value o, collector, " MINUS "
          collector << " )"
        end

        ##
        # To avoid ORA-01795: maximum number of expressions in a list is 1000
        # tell ActiveRecord to limit us to 1000 ids at a time
        def visit_Arel_Nodes_HomogeneousIn(o, collector)
          in_clause_length = @connection.in_clause_length
          values = o.casted_values.map { |v| @connection.quote(v) }
          operator =
            if o.type == :in
              " IN ("
            else
              " NOT IN ("
            end

          if !Array === values || values.length <= in_clause_length
            visit o.left, collector
            collector << operator

            expr =
              if values.empty?
                @connection.quote(nil)
              else
                values.join(",")
              end

            collector << expr
            collector << ")"
          else
            separator =
              if o.type == :in
                " OR "
              else
                " AND "
              end
            collector << "("
            values.each_slice(in_clause_length).each_with_index do |valuez, i|
              collector << separator unless i == 0
              visit o.left, collector
              collector << operator
              collector << valuez.join(",")
              collector << ")"
            end
            collector << ")"
          end

          collector
        end

        def visit_Arel_Nodes_UpdateStatement(o, collector)
          # Oracle does not allow ORDER BY/LIMIT in UPDATEs.
          if o.orders.any? && o.limit.nil?
            # However, there is no harm in silently eating the ORDER BY clause if no LIMIT has been provided,
            # otherwise let the user deal with the error
            o = o.dup
            o.orders = []
          end

          super
        end

        ###
        # Hacks for the order clauses specific to Oracle
        def order_hacks(o)
          return o if o.orders.empty?
          return o unless o.cores.any? do |core|
            core.projections.any? do |projection|
              /FIRST_VALUE/ === projection
            end
          end
          # Previous version with join and split broke ORDER BY clause
          # if it contained functions with several arguments (separated by ',').
          #
          # orders   = o.orders.map { |x| visit x }.join(', ').split(',')
          orders   = o.orders.map do |x|
            string = visit(x, Arel::Collectors::SQLString.new).value
            if string.include?(",")
              split_order_string(string)
            else
              string
            end
          end.flatten
          o.orders = []
          orders.each_with_index do |order, i|
            o.orders <<
              Nodes::SqlLiteral.new("alias_#{i}__#{' DESC' if /\bdesc$/i.match?(order)}")
          end
          o
        end

        # Split string by commas but count opening and closing brackets
        # and ignore commas inside brackets.
        def split_order_string(string)
          array = []
          i = 0
          string.split(",").each do |part|
            if array[i]
              array[i] << "," << part
            else
              # to ensure that array[i] will be String and not Arel::Nodes::SqlLiteral
              array[i] = part.to_s
            end
            i += 1 if array[i].count("(") == array[i].count(")")
          end
          array
        end

        def is_distinct_from(o, collector)
          collector << "DECODE("
          collector = visit [o.left, o.right, 0, 1], collector
          collector << ")"
        end

        # Oracle will occur an error `ORA-00907: missing right parenthesis`
        # when using `ORDER BY` in `UPDATE` or `DELETE`'s subquery.
        #
        # This method has been overridden based on the following code.
        # https://github.com/rails/rails/blob/v6.1.0.rc1/activerecord/lib/arel/visitors/to_sql.rb#L815-L825
        def build_subselect(key, o)
          stmt             = super
          stmt.orders      = [] # `orders` will never be set to prevent `ORA-00907`.
          stmt
        end
    end
  end
end
