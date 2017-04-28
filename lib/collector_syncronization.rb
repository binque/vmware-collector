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
    start_sync unless @configured #if access_granted? && !@configured
  end

  private

  # def access_granted?
  #   @configuration[:verified_api_connection] && @configuration[:verified_vsphere_connection]
  # end

  def set_configured
    VmwareConfiguration.create(configured: true)
    @configured = true
  end

  def start_sync
    logger.info 'Syncing items'

    @on_prem_connector = OnPremConnector.new
    get_infrastructures_from_vsphere
    get_infrastructures_from_api  # relies on discovered datacenters - must come after get_from_vsphere
    submit_infrastructures

    # First block of code is primarily to detect deletes
    get_machines_from_api
    api_machines = Machine.where(status: 'api')

    api_machines.each{|m| logger.debug "API machine: #{m.name}: #{m.infrastructure_remote_id}: #{m.status}"}

    # Now we sync remote IDs
    @on_prem_connector.initialize_platform_ids

    collect_machine_inventory
    collected_vsphere_machines = Machine.ne(status: 'api')
    collected_vsphere_machines.each{|m| logger.debug "Collected vsphere machine: #{m.name}: #{m.infrastructure_platform_id}: #{m.status}"}

    api_machines.each do |machine|
      unless collected_vsphere_machines.detect{|m|
               m.infrastructure_remote_id.eql?(machine.infrastructure_remote_id) and m.platform_id.match(/#{machine.platform_id}|#{machine.moref}/) }
        logger.debug "Flagging #{machine.name} in #{machine.infrastructure_remote_id} for deletion"
        machine.status = 'deleted'
        machine.record_status = 'updated'
        machine.save
      end
    end

    Machine.delete_all({status: "api"})

    set_configured
  rescue StandardError => e
    logger.error e
    logger.error e.backtrace.join("\n")
    if e.is_a?(RestClient::Exception)
      logger.error e.to_s
      logger.error e.http_body
    end
    raise e
  end

  def get_infrastructures_from_vsphere
    logger.info 'Collecting infrastructures from vsphere'
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
    # local_platform_remote_id_inventory = PlatformRemoteIdInventory.new
    # logger.debug "retrieving infrastructures from #{infrastructures_url}?organization_id=#{@configuration[:on_prem_organization_id]}"
    # response = hyper_client.get("#{infrastructures_url}?organization_id=#{@configuration[:on_prem_organization_id]}")

    #FIXME add in fallback for datacenter
    logger.info "Retrieving known infrastructures from API"

    if Infrastructure.all.size == 0
      logger.warn "No data centers discoverd. Exiting..."
      exit 1
    end

    Infrastructure.all.each do |mongo_inf|
      logger.info "retrieving infrastructure #{mongo_inf.custom_id}"
      response = hyper_client.get(infrastructure_url(infrastructure_id: mongo_inf.custom_id))
      if response.code == 200
        inf_json = JSON::parse(response.body)
        if PlatformRemoteId.where(remote_id: inf_json['id']).empty?
          logger.info "Matched #{mongo_inf.name}: creating local remote ID entry"
          PlatformRemoteId.create(infrastructure: mongo_inf.platform_id,
                                  remote_id: inf_json['id']) unless (PlatformRemoteId.where(remote_id: inf_json['id']).size > 0)
        end
        mongo_inf.update_attribute(:record_status, :updated)
      # infs['embedded']['infrastructures'].each do |inf_json|
      #   logger.debug "Checking if #{inf_json['name']}/#{inf_json['custom_id']} belongs to this collector"
      #   logger.debug inf_json
      #   infrastructure = Infrastructure.where(name: inf_json['name']).first)
      #   logger.debug infrastructure.inspect
      #   if infrastructure
      #     logger.info "Syncing infrastructure #{inf_json.to_yaml} from API with local #{infrastructure.inspect}"
      #     if PlatformRemoteId.where(remote_id: inf_json['id']).empty?
      #       PlatformRemoteId.create(infrastructure: infrastructure.platform_id,
      #                               remote_id: inf_json['id'])
      #     end
      #   end
      # end
      elsif response.code == 404
        logger.info "Infrastructure #{mongo_inf.custom_id} not found in Meter API"
      else
        logger.error "Error retrieving infrastructures from API: #{response.code}"
        logger.debug response.body
        exit 1
      end
    end
  end

  def get_machines_from_api
    hyper_client = HyperClient.new
    # local_platform_remote_id_inventory = PlatformRemoteIdInventory.new

    Infrastructure.all.each do |infrastructure|
      logger.debug "retrieving machines from #{machines_url}?infrastructure_id=#{infrastructure.remote_id}"
      logger.info "retrieving machines from #{machines_url}?infrastructure_id=#{infrastructure.remote_id}"
      response = hyper_client.get("#{machines_url}?infrastructure_id=#{infrastructure.remote_id}")

      if response.code == 200
        machines = JSON::parse(response.body)

        machines['embedded']['machines'].each do |machine_json|
          if  Machine.where(remote_id: machine_json['id']).empty?
            unless machine_json['status'].eql?('deleted')
              logger.debug "Creating machine #{machine_json['name']} from retrieved API data"
              Machine.create({ name: machine_json['name'],
                               remote_id: machine_json['id'],
                               platform_id: machine_json['custom_id'],
                               record_status: 'verified_create',
                               status: 'api',
                               infrastructure_remote_id: infrastructure.remote_id,
                               infrastructure_platform_id: infrastructure.platform_id,
                               inventory_at: @inventory_at })
            end
          end
        end
      else
        logger.error "Error retrieving machines from API: #{response.code}"
        logger.debug response.body
        exit 1
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
    logger.info "Collecting inventory for infrastructures: #{Infrastructure.all}"
    Infrastructure.all.each do |infrastructure|
      logger.info "Collecting inventory for #{infrastructure.name}"
      begin
        collector = InventoryCollector.new(infrastructure)
        collector.run(time_to_query)
      rescue StandardError => e
        logger.error e.message
        logger.debug e.backtrace.join("\n")
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
