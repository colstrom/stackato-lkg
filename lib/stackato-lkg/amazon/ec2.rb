require 'aws-sdk'
require 'contracts'
require_relative 'service'

module StackatoLKG
  module Amazon
    class EC2 < Service
      Contract None => ArrayOf[::Aws::EC2::Types::Vpc]
      def vpcs
        @vpcs ||= vpcs!
      end

      Contract None => ArrayOf[::Aws::EC2::Types::Vpc]
      def vpcs!
        @vpcs = call_api(:describe_vpcs).vpcs
      end

      Contract None => ArrayOf[::Aws::EC2::Types::Subnet]
      def subnets
        @subnets ||= subnets!
      end

      Contract None => ArrayOf[::Aws::EC2::Types::Subnet]
      def subnets!
        @subnets = call_api(:describe_subnets).subnets
      end

      Contract None => ArrayOf[::Aws::EC2::Types::Instance]
      def instances
        @instances ||= instances!
      end

      Contract None => ArrayOf[::Aws::EC2::Types::Instance]
      def instances!
        @instances = call_api(:describe_instances)
                     .reservations
                     .flat_map(&:instances)
      end

      Contract None => ArrayOf[::Aws::EC2::Types::Address]
      def addresses
        @addresses ||= addresses!
      end

      Contract None => ArrayOf[::Aws::EC2::Types::Address]
      def addresses!
        @addresses = call_api(:describe_addresses).addresses
      end

      Contract None => ArrayOf[::Aws::EC2::Types::SecurityGroup]
      def security_groups
        @security_groups ||= security_groups!
      end

      Contract None => ArrayOf[::Aws::EC2::Types::SecurityGroup]
      def security_groups!
        @security_groups = call_api(:describe_security_groups).security_groups
      end

      Contract None => ArrayOf[::Aws::EC2::Types::TagDescription]
      def tags
        @tags ||= tags!
      end

      Contract None => ArrayOf[::Aws::EC2::Types::TagDescription]
      def tags!
        @tags = call_api(:describe_tags).tags
      end

      Contract None => ::Aws::EC2::Types::Vpc
      def create_vpc
        call_api(:create_vpc, cidr_block: config.cidr_block).vpc
      end

      Contract KeywordArgs[
                 cidr_block: Optional[String],
                 vpc_id: Optional[String],
                 subnet_id: Optional[String]
               ] => ArrayOf[::Aws::EC2::Types::Subnet]
      def subnets(cidr_block: nil, vpc_id: nil, subnet_id: nil)
        subnets
          .select { |subnet| subnet_id.nil? || subnet.subnet_id == subnet_id }
          .select { |subnet| vpc_id.nil? || subnet.vpc_id == vpc_id }
          .select { |subnet| cidr_block.nil? || subnet.cidr_block == cidr_block }
      end

      Contract Args[Any] => Any
      def subnets!(**properties)
        subnets!
        subnets(properties)
      end

      Contract Args[Any] => Maybe[::Aws::EC2::Types::Subnet]
      def subnet(**properties)
        subnets(properties).first
      end

      Contract Args[Any] => Any
      def subnet!(**properties)
        subnets!
        subnet(properties)
      end

      Contract KeywordArgs[
                 cidr_block: String,
                 vpc_id: String
               ] => ::Aws::EC2::Types::Subnet
      def create_subnet(**properties)
        call_api(:create_subnet, properties).subnet
      rescue ::Aws::EC2::Errors::InvalidSubnetConflict
        subnet(properties) || subnet!(properties)
      end

      Contract RespondTo[:to_s], RespondTo[:to_i], RespondTo[:to_s], String => Bool
      def authorize_security_group_ingress(ip_protocol, port, cidr_ip, group_id)
        call_api(:authorize_security_group_ingress,
                 group_id: group_id,
                 ip_protocol: ip_protocol.to_s,
                 from_port: port.to_i,
                 to_port: port.to_i,
                 cidr_ip: cidr_ip.to_s
                ).successful?
      rescue ::Aws::EC2::Errors::InvalidPermissionDuplicate
        true
      end

      Contract RespondTo[:to_s], String => String
      def create_security_group(group_name, vpc_id)
        call_api(:create_security_group,
                 group_name: group_name.to_s,
                 description: group_name.to_s,
                 vpc_id: vpc_id).group_id
      rescue ::Aws::EC2::Errors::InvalidGroupDuplicate
        security_group(group_name.to_s, vpc_id)
      end

      Contract RespondTo[:to_s], String => String
      def security_group(group_name, vpc_id)
        security_groups
          .select { |sg| sg.vpc_id == vpc_id }
          .select { |sg| sg.group_name == group_name }
          .first
          .group_id
      end

      Contract ArrayOf[String], ArrayOf[{ key: String, value: String}] => Bool
      def create_tags(resources, tags)
        call_api(:create_tags, resources: resources, tags: tags).successful?
      end

      Contract String, Args[String] => Bool
      def assign_name(name, *resources)
        create_tags(resources, [{ key: 'Name', value: name } ])
      end

      Contract KeywordArgs[
                 type: Optional[String],
                 key: Optional[String],
                 value: Optional[String]
               ] => ArrayOf[::Aws::EC2::Types::TagDescription]
      def tagged(type: nil, key: nil, value: nil)
        tags
          .select { |tag| type.nil? || tag.resource_type == type }
          .select { |tag| tag.key == (key || 'Name') }
          .select { |tag| value.nil? || tag.value == value }
      end

      private

      def client
        Aws::EC2::Client
      end
    end
  end
end