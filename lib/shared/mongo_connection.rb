# This monkey patch allows us to add options to the pipeline
module Moped
  class Collection
    def aggregate(pipeline, opts = {})
      database.session.command({aggregate: name, pipeline: pipeline}.merge(opts))['result']
    end
  end
end

module MongoConnection
  def initialize_mongo_connection
    STDOUT.sync = true # disable output buffering; makes it hard to follow docker logs
    load_params = { sessions:
                     { default:
                         { database: '6fusion_meter',
                           hosts: [ "#{ENV['MONGODB_SERVICE_HOST']}:#{ENV['MONGODB_SERVICE_POwRT']}" ] }
                     },
                    options: {
                      pool_size: 20 }
                  }

    Mongoid::Config.load_configuration(load_params)

#    Mongoid.logger.level = mongoid_config[:mongoid_log_level]
#    Moped.logger.level   = Mongoid.logger.level

    # Test to verify we can connect
    begin
      Mongoid::Sessions.default.databases
    rescue Moped::Errors::ConnectionFailure => e
      Mongoid.logger.fatal "Could not connect to mongo instance: #{e}"
      Mongoid.logger.debug mongoid_config.to_s
      raise e
    end
  end
end
