module Jets::Resource::ApiGateway
  class RestApi < Jets::Resource::Base
    def definition
      properties = {
        name: Jets::Names.gateway_api_name,
        endpoint_configuration: { types: endpoint_types }
      }
      properties[:endpoint_configuration][:vpc_endpoint_ids] = vpce_ids if vpce_ids
      properties[:binary_media_types] = binary_media_types if binary_media_types
      properties[:policy] = endpoint_policy if endpoint_policy

      {
        internal_logical_id => {
          type: "AWS::ApiGateway::RestApi",
          properties: properties
        }
      }
    end

    def internal_logical_id
      self.class.logical_id(true)
    end

    def self.logical_id(internal=false)
      internal ? internal_logical_id : "RestApi"
    end

    @@internal_logical_id = nil
    def self.internal_logical_id
      @@internal_logical_id ||= LogicalId.new.get
    end

    def outputs
      {
        "RestApi" => "!Ref #{internal_logical_id}",
        "Region" => "!Ref AWS::Region",
        "RootResourceId" => "!GetAtt #{internal_logical_id}.RootResourceId",
      }
    end

    def endpoint_types
      [Jets.config.api.endpoint_type].flatten
    end

    # TODO: Looks like there's a bug with CloudFormation. On an API Gateway update
    # we need to pass in the escaped version: multipart~1form-data
    # On a brand new API Gateway creation, we need to pass in the unescaped form:
    # multipart/form-data
    # We are handling this with a full API Gateway replacement instead because it
    # can be generalized more easily.
    def binary_media_types
      types = Jets.config.api.binary_media_types
      return nil if types.nil? || types.empty?

      [types].flatten
    end

    def endpoint_policy
      endpoint_policy = Jets.config.api.endpoint_policy
      return nil if endpoint_policy.nil? || endpoint_policy.empty?

      endpoint_policy
    end

    private

    def vpce_ids
      ids = Jets.config.api.vpc_endpoint_ids
      return nil if ids.nil? || ids.empty?

      ids
    end
  end
end
