require 'aws-sdk'
require 'contracts'
require_relative 'service'

module Cloudstrap
  module Amazon
    class Route53 < Service
      include ::Contracts::Core
      include ::Contracts::Builtin

      Contract None => ArrayOf[::Aws::Route53::Types::HostedZone]
      def zones
        @zones ||= zones!
      end

      Contract None => ArrayOf[::Aws::Route53::Types::HostedZone]
      def zones!
        @zones = call_api(:list_hosted_zones).hosted_zones
      end

      Contract String => Maybe[::Aws::Route53::Types::HostedZone]
      def zone(name)
        name = name.end_with?('.') ? name : name.dup.concat('.')

        zones.find { |zone| zone.name == name }
      end

      Contract String => ArrayOf[String]
      def zone_names
        @zone_names ||= zones.map(&:name)
      end

      Contract String => Maybe[String]
      def longest_matching_suffix(name)
        fragments = name.split '.'
        fragments
          .each_with_index
          .map { |_, i| fragments.drop(i).join('.') + '.' }
          .find { |fragment| zone_names.include? fragment }
      end

      Contract String => Maybe[String]
      def zone_id(name)
        return unless zone = zone(name)

        zone(name).id.split('/').last
      end

      private

      def client
        ::Aws::Route53::Client
      end
    end
  end
end
