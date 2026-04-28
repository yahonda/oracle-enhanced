# frozen_string_literal: true

# Surfaces visibility drift between oracle_enhanced and Rails.
#
# For every instance method defined inside an `OracleEnhanced::*` module or
# class reachable from one of the `ROOTS` below, this script finds the nearest
# non-OE Rails adapter ancestor that also defines that method and compares the
# Ruby visibility (public / private / protected). Any mismatch is reported,
# and the script exits non-zero so CI can catch it.
#
# `ROOTS` includes the adapter class plus other OE-namespaced classes whose
# ancestor chains do not run through `OracleEnhancedAdapter` (visitors,
# schema-dump, and the per-object subclasses in `schema_definitions.rb` /
# `column.rb`).
#
# Because each root's ancestor chain is walked independently, the script does
# not care which Rails module the counterpart lives in. A method we define in
# `OracleEnhanced::SchemaStatements` that Rails defines directly on
# `AbstractAdapter` (or vice versa) is still detected as a drift as long as
# both sides name the method the same way.
#
# What this does NOT catch (known limitations):
#
# - Methods Rails renames / relocates without keeping the old name. If Rails
#   turns `foo` into `bar`, this script sees two unrelated methods.
# - Methods that only exist as class methods (`self.foo`) — only instance
#   methods are compared.
# - Semantic drift — signature changes and behavioural differences are
#   invisible to a visibility check.
# - `# :nodoc:` markers — those are source-level comments, not reflectable at
#   runtime. A follow-up could parse the AST if this becomes important.
#
# Run locally:
#   bundle exec ruby -Ilib ci/check_method_visibility.rb

require "active_record"
require "active_record/connection_adapters/oracle_enhanced_adapter"

# Roots whose ancestor chains are walked. The adapter class itself covers
# everything `OracleEnhancedAdapter.ancestors` reaches —
# `OracleEnhanced::SchemaStatements`, `Quoting`, `DatabaseStatements`, etc.
# The other entries pick up classes that override Rails contracts but are not
# in the adapter's ancestor chain: visitors (`SchemaCreation`), schema-dump
# (`SchemaDumper`), and the per-object subclasses defined in
# `connection_adapters/oracle_enhanced/schema_definitions.rb` and `column.rb`.
ROOTS = [
  ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter,
  ActiveRecord::ConnectionAdapters::OracleEnhanced::SchemaCreation,
  ActiveRecord::ConnectionAdapters::OracleEnhanced::SchemaDumper,
  ActiveRecord::ConnectionAdapters::OracleEnhanced::Column,
  ActiveRecord::ConnectionAdapters::OracleEnhanced::ReferenceDefinition,
  ActiveRecord::ConnectionAdapters::OracleEnhanced::IndexDefinition,
  ActiveRecord::ConnectionAdapters::OracleEnhanced::TableDefinition,
  ActiveRecord::ConnectionAdapters::OracleEnhanced::AlterTable,
  ActiveRecord::ConnectionAdapters::OracleEnhanced::Table,
].freeze

# Drifts listed here are intentionally accepted, with a one-line reason. Keep
# this set small and give it a good justification — the whole point of the
# check is to flag *unintentional* drift.
IGNORED_DRIFTS = [
  # { method: :some_method, oe_owner: "Some::Module", rails_owner: "Some::Rails" },
].freeze

OE_NAMESPACE = /(^|::)OracleEnhanced(?:Adapter)?(?:::|$)/

def oe_owned?(owner)
  owner.name && owner.name.match?(OE_NAMESPACE)
end

def rails_owned?(owner)
  name = owner.name
  return false unless name
  return false if oe_owned?(owner)
  # Only consider Rails adapter-contract namespaces. ActiveSupport mixins
  # (Callbacks, Tryable, ...) and ActiveRecord non-adapter modules
  # (Migration, QueryCache helpers, ...) are deliberately out of scope for
  # this adapter-visibility check.
  name.start_with?("ActiveRecord::ConnectionAdapters::") ||
    name.start_with?("Arel::")
end

def visibility_of(owner, method_name)
  return :public    if owner.public_instance_methods(false).include?(method_name)
  return :private   if owner.private_instance_methods(false).include?(method_name)
  return :protected if owner.protected_instance_methods(false).include?(method_name)
  nil
end

# Find the nearest Rails (non-OE) ancestor that defines method_name, walking
# the class's ancestor list in MRO order. Returns [ancestor_owner, visibility]
# or nil.
def find_rails_counterpart(ancestors, method_name)
  ancestors.each do |owner|
    next unless rails_owned?(owner)
    vis = visibility_of(owner, method_name)
    return [owner, vis] if vis
  end
  nil
end

def ignored?(drift)
  IGNORED_DRIFTS.any? do |pat|
    pat[:method].to_s == drift[:method].to_s &&
      pat[:oe_owner] == drift[:oe_owner] &&
      pat[:rails_owner] == drift[:rails_owner]
  end
end

drifts = []
seen = {}

ROOTS.each do |root|
  ancestors = root.ancestors
  oe_ancestors = ancestors.select { |owner| oe_owned?(owner) }

  oe_ancestors.each do |oe_owner|
    own_methods = oe_owner.public_instance_methods(false) +
                  oe_owner.private_instance_methods(false) +
                  oe_owner.protected_instance_methods(false)

    own_methods.sort.each do |method_name|
      key = [oe_owner.object_id, method_name]
      next if seen[key]
      seen[key] = true

      rails_pair = find_rails_counterpart(ancestors, method_name)
      next unless rails_pair

      rails_owner, rails_vis = rails_pair
      oe_vis = visibility_of(oe_owner, method_name)
      next if oe_vis == rails_vis

      drift = {
        method: method_name,
        oe_owner: oe_owner.name,
        oe_vis: oe_vis,
        rails_owner: rails_owner.name,
        rails_vis: rails_vis,
      }
      drifts << drift unless ignored?(drift)
    end
  end
end

if drifts.empty?
  puts "OK: every overridden method matches the Rails counterpart's visibility."
  exit 0
end

puts "Visibility drift detected (#{drifts.size} method#{drifts.size == 1 ? '' : 's'}):"
drifts.sort_by { |d| [d[:oe_owner], d[:method].to_s] }.each do |d|
  puts "  - #{d[:method]}"
  puts "      #{d[:oe_owner]}: #{d[:oe_vis]}"
  puts "      #{d[:rails_owner]}: #{d[:rails_vis]}"
end
puts
puts "If the drift is intentional (Rails changed its contract and we are tracking"
puts "the old behavior deliberately), add an entry to IGNORED_DRIFTS in this"
puts "script with a one-line comment explaining why. Otherwise, reconcile"
puts "oracle_enhanced with Rails by moving the method's visibility to match."
exit 1
