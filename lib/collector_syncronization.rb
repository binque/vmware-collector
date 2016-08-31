require 'uri'
require 'securerandom'

require 'global_configuration'
require 'logging'
require 'vsphere_session'
require 'metrics_collector'
require 'infrastructure_collector'
require 'inventory_collector'
require 'on_prem_connector'
require 'on_prem_url_generator'
require 'interval_time'

class CollectorSyncronization
  using IntervalTime
  include GlobalConfiguration
  include OnPremUrlGenerator
  include Logging
  include VSphere

  def initialize
    @environment = ENV['METER_ENV'] || 'development'
    @configuration = GlobalConfiguration::GlobalConfig.instance
    @configured = !VmwareConfiguration.empty?
  end

  def sync_data
    start_sync if access_granted? && !@configured
  end

  private

  def access_granted?
    @configuration[:verified_api_connection] && @configuration[:verified_vsphere_connection]
  end

  def set_configured
    VmwareConfiguration.create(configured: true)
    @configured = true
  end

  def start_sync
    logger.info 'Syncing items'

    @on_prem_connector = OnPremConnector.new
    get_infrastructures_from_api
    submit_infrastructures
    collect_machine_inventory
    sync_remote_ids
    set_configured
  rescue StandardError => e
    logger.error e
    logger.error e.backtrace.join("\n")
    if e.is_a?(RestClient::Exception)
      logger.error e.to_s
      logger.error e.http_body
    end
  end

  def collect_infrastructures
    logger.info 'Collecting insfrastructures'
    infrastructures = Infrastructure.all
    InfrastructureCollector.new.run
    if Infrastructure.empty?
      logger.info 'No infrastructures discovered'
    else
      logger.info "#{infrastructures.count} infrastructure#{'s' if infrastructures.count > 1} discovered"
    end
  end

  def get_infrastructures_from_api
    hyper_client = HyperClient.new
    local_platform_remote_id_inventory = PlatformRemoteIdInventory.new
    response = hyper_client.get(infrastructures_url)

    if response.code == 200
      infs = JSON::parse(response.body)

      infs['embedded']['infrastructures'].each do |inf_json|
        if  Infrastructure.where(remote_id: inf_json['id']).empty?
          infrastructure = Infrastructure.create({ name: inf_json['name'],
                                                   remote_id: inf_json['id'],
                                                   platform_id: inf_json['custom_id'],
                                                   record_status: 'verified_create' })
          PlatformRemoteId.create(infrastructure: inf_json['custom_id'],
                                  remote_id: inf_json['id'])
        end
      end
    end

  end


  def submit_infrastructures
    logger.info 'Submitting infrastructures'
    @on_prem_connector.submit_infrastructure_creates
    # We rely on the passwords having been added to the global config, *unencrypted*, in the previous registration steps
    #  So we save them before moving into the code to set up encryption
    proxy = @configuration[:on_prem_proxy_password]
    vsphere = @configuration[:vsphere_password]
    hyper_client = HyperClient.new
    response = hyper_client.get(infrastructures_url)

    if response.code == 200
      @configuration[:on_prem_proxy_password] = proxy
      @configuration[:vsphere_password] = vsphere
    else
      logger.error "Something other than a 200 returned at #{__LINE__}: #{response.code}"
      logger.debug response.body
    end
    logger.info 'Submitted infrastructures'
  end

  def collect_machine_inventory
    time_to_query = Time.now.truncated
    Infrastructure.enabled.each do |infrastructure|
      logger.info "Collecting inventory for #{infrastructure.name}"
      begin
        collector = InventoryCollector.new(infrastructure)
        collector.run(time_to_query)
      rescue StandardError => e
        logger.error e.message
        logger.debug e.backtrace.join("\n")
        infrastructure.disable
      end
    end
    machine_count = Machine.distinct(:platform_id).count
    # raise 'No virtual machine inventory discovered' if machine_count == 0
    if machine_count == 0
      logger.warn 'No virtual machine inventory discovered'
    else
      logger.info "#{machine_count} virtual machine#{'s' if machine_count > 1} discovered"
    end
  end

  def sync_remote_ids
    logger.info 'Syncing remote ids'
    @on_prem_connector.initialize_platform_ids { |msg| logger.info msg }
    logger.info 'Local inventory synced with OnPrem'
  end
end
