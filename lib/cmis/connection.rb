require 'cmis/connection/request_modifier'
require 'cmis/connection/response_parser'
require 'cmis/version'
require 'faraday'

module CMIS
  class Connection
    def initialize(options)
      message = "option `service_url` must be set"
      @service_url = options[:service_url] or raise message

      @http = Faraday.new(connection_options(options)) do |builder|
        builder.use RequestModifier
        builder.request :multipart
        builder.request :url_encoded

        if options[:username]
          builder.basic_auth(options[:username], options[:password])
        end

        builder.adapter (options[:adapter] || :net_http).to_sym
        builder.response :logger if options[:log_requests]
        builder.use ResponseParser
      end

      @repository_infos = {}
    end

    def do_request(params, query, headers)
      repository_id = params.delete(:repositoryId)
      url = infer_url(repository_id, params[:objectId])

      if params[:cmisaction]
        @http.post(url, params, headers)
      else
        @http.get(url, params.merge(query), headers)
      end
    end

    private

    def connection_options(options)
      adapter = (options[:adapter] || :net_http).to_sym
      headers = { user_agent: "cmis-ruby/#{VERSION} [#{adapter}]" }
      headers.merge!(options[:headers]) if options[:headers]

      conn_opts = { headers: headers }
      conn_opts[:ssl] = options[:ssl] if options[:ssl]

      conn_opts
    end

    def infer_url(repository_id, object_id)
      return @service_url unless repository_id

      unless @repository_infos.key?(repository_id)
        @repository_infos = @http.get(@service_url).body
      end

      if @repository_infos.key?(repository_id)
        key = object_id ? 'rootFolderUrl' : 'repositoryUrl'
        @repository_infos[repository_id][key]
      else
        raise Exceptions::ObjectNotFound, "repositoryId: #{repository_id}"
      end
    end
  end
end
