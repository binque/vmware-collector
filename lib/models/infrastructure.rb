require 'global_configuration'
require 'host'
require 'infrastructure_collector'
require 'logging'
require 'matchable'
require 'network'
require 'on_prem_url_generator'

class Infrastructure
  include Mongoid::Document
  include Mongoid::Timestamps
  include Logging
  include Matchable
  include GlobalConfiguration
  include OnPremUrlGenerator

  field :platform_id, type: String
  field :remote_id, type: String
  field :name, type: String
  field :record_status, type: String
  # Tags are currently static defaults only, not updated during collection
  field :tags, type: Array, default: ['platform:VMware', 'collector:VMware']

  field :status, type: String, default: 'online'
  field :vcenter_server, type: String # !! hmmmm
  # field :release_version, type: String, default: 'alpha'

  embeds_many :hosts
  embeds_many :networks
  embeds_many :volumes

  accepts_nested_attributes_for :hosts
  accepts_nested_attributes_for :networks
  accepts_nested_attributes_for :volumes

  # Infrastructure Statuses: created, updated, deleted, verified_create, verified_update
  scope :to_be_created_or_updated, -> { where(:record_status.in => %w(created updated)) }

  index(record_status: 1)

  # TODO: Verify if we still need this index

  def total_server_count
    @total_server_count ||= hosts.size
  end

  def total_cpu_cores
    @total_cpu_cores ||= infrastructure_totals[:cpu_cores]
  end

  def total_cpu_mhz
    @total_cpu_mhz ||= infrastructure_totals[:cpu_mhz]
  end

  def total_memory
    @total_memory ||= infrastructure_totals[:memory]
  end

  def total_sockets
    @total_sockets ||= infrastructure_totals[:sockets]
  end

  def total_threads
    @total_threads ||= infrastructure_totals[:threads]
  end

  def total_storage_bytes
    @total_storage_bytes ||= infrastructure_totals[:storage_bytes]
  end

  def total_lan_bandwidth_mbits
    @total_lan_bandwidth_mbits ||= infrastructure_totals[:lan_bandwidth_mbits]
  end

  def infrastructure_totals
    @infrastructure_totals ||= begin
      totals = Hash.new { |h, k| h[k] = 0 }
      hosts.each do |host|
        totals[:cpu_cores] += host.cpu_cores
        totals[:cpu_mhz]   += host.cpu_hz
        totals[:memory]    += host.memory
        totals[:sockets]   += host.sockets
        totals[:threads]   += host.threads
        totals[:lan_bandwidth_mbits] += host.total_lan_bandwidth
      end

      volumes.each do |volume|
        totals[:storage_bytes] += volume.storage_bytes
      end

      totals
    end
  end

  def submit_create
    response = nil
    begin
      logger.info "Submitting #{name_with_prefix} to API for creation in OnPrem"
      response = hyper_client.post(infrastructures_post_url, api_format)
      if response && response.code == 200
        self.remote_id = response.json['id']
        update_attribute(:record_status, 'verified_create') # record_status will be ignored by local_inventory class, so we need to update it "manually"
      else
        logger.error "Unable to create infrastructure in OnPrem for #{name_with_prefix}"
        logger.debug "API reponse: #{response}"
      end
    rescue StandardError => e
      logger.error "Error creating infrastructure in OnPrem for #{name_with_prefix}"
      logger.error e.message
      logger.debug e
      raise
    end
    self
  end

  def submit_update
    logger.info "Updating infrastructure #{name_with_prefix} in OnPrem API"
    begin
      response = hyper_client.put(infrastructure_url(infrastructure_id: remote_id), api_format.merge(status: 'Active'))
      response_json = response.json
      if (response.present? && response.code == 200 && response_json['id'].present?)
        self.record_status = 'verified_update'
      end
    rescue RuntimeError => e
      logger.error "Error updating infrastructure '#{name_with_prefix} in OnPrem"
      raise e
    end
    self
  end

  def attribute_map
    { name: :name_with_prefix }
  end

  def vm_to_host_map
    @vm_to_host_map ||= begin
      h = {}
      hosts.each do |host|
        host.inventory.each { |vm| h[vm] = host }
      end
      h
    end
  end

  def hyper_client
    @hyper_client ||= HyperClient.new
  end

  def name_with_prefix
    ENV['VCENTER_LABEL'] ?
      "#{ENV['VCENTER_LABEL']} #{name}" :
      name
  end

  # Format to submit to OnPrem Console API
  def api_format
    {
      name: name_with_prefix,
      custom_id: platform_id,
      tags: tags,
      summary: {
        # Counts
        hosts: hosts.size,
        networks: networks.size,
        volumes: volumes.size,

        # Sums
        sockets: total_sockets,
        cores: total_cpu_cores,
        threads: total_threads,
        speed_mhz: total_cpu_mhz,
        memory_bytes: total_memory,
        storage_bytes: total_storage_bytes,
        lan_bandwidth_mbits: total_lan_bandwidth_mbits,
        wan_bandwidth_mbits: 0
      },

      # Nested models
      hosts: hosts.map(&:api_format),
      networks: networks_with_defaults,
      volumes: volumes.map(&:api_format)
    }
  end

  def networks_with_defaults
    ([ Network.new(name: 'default_wan', kind: 'WAN') ] |
      [ Network.new(name: 'default_san', kind: 'SAN') ] |
     networks).map(&:api_format)
  end

end
