require 'httparty'
require 'net/http/post/multipart'
require 'multi_json'
require 'volatile_hash'

module YACCL
  module Services
    class CMISRequestError < RuntimeError; end

    module Internal
      class BrowserBindingService
        def initialize(service_url, basic_auth_username=nil, basic_auth_password=nil, succinct_properties=true)
          @service_url = service_url
          @basement = Basement.new(basic_auth_username, basic_auth_password)

          @succinct_properties = succinct_properties

          @repository_urls = VolatileHash.new(strategy: 'lru')
          @root_folder_urls = VolatileHash.new(strategy: 'lru')
        end

        def perform_request(required_params={}, optional_params={})
          url = get_url(required_params.delete(:repositoryId), required_params[:objectId])

          required_params[:succinct] ||= @succinct_properties
          optional_params.reject! { |_, v| v.nil? }

          params = transform_hash(required_params.merge(optional_params))

          check(params)

          response = if params.has_key?(:cmisaction)
            if params.has_key?(:content)
              @basement.multipart_post(url, params)
            else
              @basement.post(url, body: params)
            end
          else
            @basement.get(url, query: params)
          end

          result = response.body
          if response.content_type == 'application/json'
            result = MultiJson.load(result, symbolize_keys: true)
          end
          unless (200...300).include?(response.code.to_i)
            if result.is_a?(Hash) && result.has_key?(:exception)
              raise CMISRequestError, "#{result[:exception]} -- #{result[:message]}"
            else
              raise CMISRequestError, "#{result}"
            end
          end

          result
        end

        private

        def get_url(repository_id, object_id)
          if repository_id.nil?
            @service_url
          else
            if object_id.nil?
              if @repository_urls[repository_id].nil?
                base = @basement.get(@service_url)
                raise "No repository found with ID: #{repository_id}." unless base[repository_id]
                repository_url = base[repository_id]['repositoryUrl']
                @repository_urls[repository_id] = repository_url
              end
              return @repository_urls[repository_id]
            else
              if @root_folder_urls[repository_id].nil?
                root_folder_url = @basement.get(@service_url)[repository_id]['rootFolderUrl']
                @root_folder_urls[repository_id] = root_folder_url
              end
              return @root_folder_urls[repository_id]
            end
          end
        end

        def check(hash)
          check_in(hash, :includeRelationships, [:none, :source, :target, :both])
        end

        def check_in(hash, key, arr)
          value = hash[key]
          unless value.nil?
            unless arr.include?(value)
              raise ArgumentError, "#{key} must be one of #{arr}."
            end
          end
        end

        def transform_hash(hash)
          if hash.has_key?(:content)
            content = hash.delete(:content)
            hash[:content] = UploadIO.new(content[:stream],
                                          content[:mime_type],
                                          content[:filename])
          end
          if hash.has_key?(:properties)
            props = hash.delete(:properties)
            if props.is_a?(Hash)
              props.each_with_index do |(id, value), index|
                if value.is_a?(Time) || value.is_a?(DateTime)
                  value = (value.to_f * 1000).to_i
                end
                hash.merge!("propertyId[#{index}]" => id,
                            "propertyValue[#{index}]" => value)
              end
            end
          end
          hash
        end

        class Basement
          include HTTParty

          def initialize(user, pass)
            @username = user
            @password = pass
            self.class.basic_auth(user, pass)
          end

          def get(*params)
            self.class.get(*params)
          end

          def post(*params)
            self.class.post(*params)
          end

          def multipart_post(url, options)
            url = URI.parse(url)
            req = Net::HTTP::Post::Multipart.new(url.path, options)
            req.basic_auth @username, @password unless @username.nil?
            opts = { use_ssl: url.scheme == 'https' }
            Net::HTTP.start(url.host, url.port, opts) { |http| http.request(req) }
          end
        end
      end
    end
  end
end
