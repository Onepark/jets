module Jets::Resource::Iam
  module BaseRoleDefinition
    attr_reader :policy_definitions, :managed_policy_definitions

    def definition
      logical_id = role_logical_id

      # Do not assign pretty role_name because long controller names might hit the 64-char
      # limit. Also, IAM roles are global, so assigning role names prevents cross region deploys.
      definition = {
        logical_id => {
          type: "AWS::IAM::Role",
          properties: {
            path: "/",
            assume_role_policy_document: {
              version: "2012-10-17",
              statement: [{
                effect: "Allow",
                principal: {service: ["lambda.amazonaws.com"]},
                action: ["sts:AssumeRole"]}
              ]
            }
          }
        }
      }

      # Add vpc permissions to all policies
      definition[logical_id][:properties][:policies] = [
        policy_name: "vpc", # required, limited to 128-chars
        policy_document: vpc_policy_document,
      ] if vpc_policy_document

      unless managed_policy_arns.empty?
        definition[logical_id][:properties][:managed_policy_arns] = managed_policy_arns
      end

      definition
    end

    def vpc_policy_document
      if Jets.config.function.vpc_config
        {
          Statement: [Jets::Application.vpc_iam_policy_statement]
        }
      end
    end

    def policy_document
      PolicyDocument.new(@policy_definitions.flatten.uniq).policy_document
    end

    def managed_policy_arns
      ManagedPolicy.new(@managed_policy_definitions.flatten.uniq).arns
    end
  end
end