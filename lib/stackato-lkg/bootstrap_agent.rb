require 'contracts'
require 'moneta'
require 'securerandom'

require_relative 'amazon'
require_relative 'config'
require_relative 'hdp/bootstrap_properties'
require_relative 'ssh'

module StackatoLKG
  class BootstrapAgent
    include ::Contracts::Core
    include ::Contracts::Builtin

    Contract None => String
    def create_vpc
      cache.store(:vpc_id, ec2.create_vpc.vpc_id).tap do |vpc_id|
        ec2.assign_name(bootstrap_tag, vpc_id)
      end
    end

    Contract None => Maybe[String]
    def find_vpc
      ENV.fetch('BOOTSTRAP_VPC_ID') do
        cache.fetch(:vpc_id) do
          cache.store :vpc_id, ec2
                               .tagged(type: 'vpc', value: bootstrap_tag)
                               .map(&:resource_id)
                               .first
        end
      end
    end

    Contract None => String
    def internet_gateway
      find_internet_gateway || create_internet_gateway
    end

    Contract None => String
    def create_internet_gateway
      cache.store(:internet_gateway_id,
                   ec2.create_internet_gateway.internet_gateway_id
                  ).tap { |internet_gateway_id| ec2.assign_name bootstrap_tag, internet_gateway_id }
    end

    Contract None => Maybe[String]
    def find_internet_gateway
      ENV.fetch('BOOTSTRAP_INTERNET_GATEWAY_ID') do
        cache.fetch(:internet_gateway_id) do
          find_tagged_internet_gateway || find_internet_gateway_for_vpc
        end
      end
    end

    Contract None => Maybe[String]
    def find_tagged_internet_gateway
      ec2
        .tagged(type: 'internet-gateway', value: bootstrap_tag)
        .map { |resource| resource.resource.id }
        .first
    end

    Contract None => Maybe[String]
    def find_internet_gateway_for_vpc
      ec2
        .internet_gateways
        .select { |gateway| gateway.attachments.any? { |attachment| attachment.vpc_id == vpc } }
        .map { |gateway| gateway.internet_gateway_id }
        .first
    end

    Contract None => String
    def create_jumpbox_security_group
      cache.store(:jumpbox_security_group, ec2.create_security_group(:jumpbox, vpc)).tap do |sg|
        ec2.assign_name(bootstrap_tag, sg)
      end
    end

    Contract None => Maybe[String]
    def find_jumpbox_security_group
      @jumpbox_security_group ||= ENV.fetch('BOOTSTRAP_JUMPBOX_SECURITY_GROUP') do
        cache.fetch(:jumpbox_security_group) do
          cache.store :jumpbox_security_group, ec2
                                           .tagged(type: 'security-group', value: bootstrap_tag)
                                           .map(&:resource_id)
                                           .first
        end
      end
    end

    Contract None => Bool
    def allow_ssh
      ec2.authorize_security_group_ingress :tcp, 22, '0.0.0.0/0', jumpbox_security_group
    end

    Contract None => String
    def jumpbox_security_group
      find_jumpbox_security_group || create_jumpbox_security_group
    end

    Contract None => String
    def private_subnet
      @private_subnet ||= ENV.fetch('BOOTSTRAP_PRIVATE_SUBNET_ID') do
        cache.fetch(:private_subnet_id) do
          properties = { vpc_id: vpc, cidr_block: config.private_cidr_block }
          cache.store(:private_subnet_id, (ec2.subnet(properties) || ec2.create_subnet(properties)).tap do |subnet|
            ec2.assign_name bootstrap_tag, subnet.subnet_id unless subnet.tags.any? do |tag|
              tag.key == 'Name' && tag.value = bootstrap_tag
            end
          end.subnet_id)
        end
      end
    end

    Contract None => String
    def public_subnet
      @public_subnet ||= ENV.fetch('BOOTSTRAP_PUBLIC_SUBNET_ID') do
        cache.fetch(:public_subnet_id) do
          properties = { vpc_id: vpc, cidr_block: config.public_cidr_block }
          cache.store(:public_subnet_id, (ec2.subnet(properties) || ec2.create_subnet(properties)).tap do |subnet|
                        ec2.assign_name bootstrap_tag, subnet.subnet_id unless subnet.tags.any? do |tag|
                          tag.key == 'Name' && tag.value = bootstrap_tag
                        end
                      end.subnet_id)
        end
      end
    end

    Contract None => String
    def route_table
      @route_table ||= ENV.fetch('BOOTSTRAP_ROUTE_TABLE_ID') do
        cache.fetch(:route_table_id) do
          cache.store(:route_table_id, ec2
                                       .route_tables
                                       .select { |route_table| route_table.vpc_id == vpc }
                                       .map { |route_table| route_table.route_table_id }
                                       .first).tap do |route_table_id|
            ec2.assign_name bootstrap_tag, route_table_id
          end
        end
      end
    end

    Contract None => Bool
    def attach_gateway
      ec2.attach_internet_gateway internet_gateway, vpc # TODO: Cache this
    end

    Contract None => Bool
    def default_route
      ec2.create_route('0.0.0.0/0', internet_gateway, route_table)  # TODO: Cache this
    end

    Contract None => ArrayOf[String]
    def subnets
      [public_subnet, private_subnet]
    end

    Contract None => Bool
    def enable_public_ips
      ec2.map_public_ip_on_launch?(public_subnet) || ec2.map_public_ip_on_launch(public_subnet, true)
    end

    Contract None => String
    def vpc
      find_vpc || create_vpc
    end

    Contract None => String
    def create_jumpbox
      upload_ssh_key

     cache.store(:jumpbox_id, ec2.create_instance(
                   image_id: ami,
                   instance_type: config.instance_type,
                   key_name: bootstrap_tag,
                   client_token: Digest::SHA256.hexdigest(bootstrap_tag),
                   network_interfaces: [{
                                          device_index: 0,
                                          subnet_id: public_subnet,
                                          associate_public_ip_address: true,
                                          groups: [jumpbox_security_group]
                                        }]
                 ).instance_id).tap do |instance_id|
       ec2.assign_name bootstrap_tag, instance_id
     end
    end

    Contract None => Maybe[String]
    def find_jumpbox
      ENV.fetch('BOOTSTRAP_JUMPBOX_ID') do
        cache.fetch(:jumpbox_id) do
          ec2
            .tagged(type: 'instance', value: bootstrap_tag)
            .map(&:resource_id)
            .first
        end
      end
    end

    Contract None => String
    def jumpbox
      find_jumpbox || create_jumpbox
    end

    Contract None => String
    def ami
      @ami ||= ENV.fetch('BOOTSTRAP_AMI') do
        cache.fetch(:ami_id) do
          cache.store :ami_id, ec2.latest_ubuntu(config.ubuntu_release).image_id
        end
      end
    end

    Contract None => String
    def upload_ssh_key
      ec2.import_key_pair bootstrap_tag, ssh_key.to_s # TODO: Cache this.
    end

    Contract None => SSH::Key
    def ssh_key
      @ssh_key ||= SSH::Key.new bootstrap_tag
    end

    Contract None => String
    def bootstrap_tag
      @bootstrap_tag ||= ENV.fetch('BOOTSTRAP_TAG') do
        "lkg@#{username}/#{uuid}"
      end
    end

    Contract None => String
    def username
      @username ||= ENV.fetch('BOOTSTRAP_USERNAME') do
        cache.fetch(:username) do
          cache.store(:username, iam.user.user_name)
        end
      end
    end

    Contract None => String
    def uuid
      @uuid ||= ENV.fetch('BOOTSTRAP_UUID') do
        cache.fetch(:uuid) do
          cache.store(:uuid, SecureRandom.uuid)
        end
      end
    end

    Contract None => String
    def availability_zone
      @availability_zone ||= ENV.fetch('BOOTSTRAP_AVAILABILITY_ZONE') do
        cache.fetch(:availability_zone) do
          cache.store(:availability_zone, ec2
                                          .subnets
                                          .select { |subnet| subnet.subnet_id == public_subnet }
                                          .map { |subnet| subnet.availability_zone }
                                          .first)
        end
      end
    end

    Contract None => String
    def jumpbox_ip
      @jumpbox_ip ||= ENV.fetch('BOOTSTRAP_JUMPBOX_IP') do
        cache.fetch(:jumpbox_ip) do
          cache.store(:jumpbox_ip, ec2
                                   .instances
                                   .select { |instance| instance.instance_id == jumpbox }
                                   .flat_map(&:network_interfaces)
                                   .map(&:association)
                                   .map(&:public_ip)
                                   .first)
        end
      end
    end

    Contract None => Bool
    def configure_hdp
      bootstrap_properties
        .update('AWS.Region', config.region)
        .update('AWS.AvailabilityZones', availability_zone)
        .update('AWS.Keypair', bootstrap_tag)
        .update('AWS.KeypairFile', '/home/ubuntu/.ssh/id_rsa')
        .update('AWS.JumpboxCIDR', '0.0.0.0/0')
        .update('AWS.VPCID', vpc)
        .update('AWS.LinuxAMI', ami)
        .save!
    end

    Contract None => Bool
    def jumpbox_running?
      ec2
        .instances
        .select { |instance| instance.instance_id == jumpbox }
        .map { |instance| instance.state.name }
        .first == 'running'
    end

    Contract None => Any
    def configure_jumpbox
      private_key = ssh_key.private_file
      properties = bootstrap_properties.file

      ssh.to(jumpbox_ip) do
        '/home/ubuntu/.ssh/id_rsa'.tap do |target|
          execute :chmod, '+w', target
          upload! private_key, target
          execute :chmod, '-w', target
        end

        upload! properties, '/home/ubuntu/bootstrap.properties'

        as :root do
          execute :apt, *%w(install --assume-yes genisoimage)
        end
      end
    end

    private

    Contract None => SSH::Client
    def ssh
      @ssh ||= SSH::Client.new(ssh_key.private_file)
    end

    Contract None => HDP::BootstrapProperties
    def bootstrap_properties
      @hdp ||= HDP::BootstrapProperties.new
    end

    Contract None => Amazon::EC2
    def ec2
      @ec2 ||= Amazon::EC2.new
    end

    Contract None => Amazon::IAM
    def iam
      @iam ||= Amazon::IAM.new
    end

    Contract None => Config
    def config
      @config ||= Config.new
    end

    Contract None => Moneta::Proxy
    def cache
      @cache ||= Moneta.new :File, dir: config.cache_path
    end
  end
end
