require 'uri'
require 'securerandom'

require 'global_configuration'
require 'logging'
require 'vsphere_session'
require 'metrics_collector'
require 'infrastructure_collector'
require 'inventory_collector'
require 'uc6_connector'
require 'uc6_url_generator'
require 'interval_time'

class CollectorSyncronization
  using IntervalTime
  include GlobalConfiguration
  include UC6UrlGenerator
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
    @uc6_connector = UC6Connector.new
    collect_infrastructures
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

  def submit_infrastructures
    logger.info 'Submitting infrastructures'
    @uc6_connector.submit_infrastructure_creates
    # We rely on the passwords having been added to the global config, *unencrypted*, in the previous registration steps
    #  So we save them before moving into the code to set up encryption
    proxy   = @configuration[:uc6_proxy_password]
    vsphere = @configuration[:vsphere_password]
    hyper_client = HyperClient.new
    response = hyper_client.get(infrastructures_url)

    if response.code == 200
      @configuration[:uc6_proxy_password] = proxy
      @configuration[:vsphere_password] = vsphere
    else
      logger.error "Something other than a 200 returned at #{__LINE__}: #{response.code}"
      logger.debug response.body
    end
    logger.info 'Submitted infrastructures'
  end

  def collect_machine_inventory
    time_to_query = Time.now.truncated
    inventoried_timestamp = InventoriedTimestamp.find_or_create_by(inventory_at: time_to_query)
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
    raise 'No virtual machine inventory discovered' if machine_count == 0
    inventoried_timestamp.delete # Leaving this behind creates "gaps" between this inventory time and when the user clicks "start metering"
    logger.info "#{machine_count} virtual machine#{'s' if machine_count > 1} discovered"
  end

  def sync_remote_ids
    logger.info 'Syncing remote ids'
    @uc6_connector.initialize_platform_ids { |msg| logger.info msg }
    logger.info 'Local inventory synced with UC6'
  end
end