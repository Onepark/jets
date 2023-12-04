# frozen_string_literal: true

module Jets
  module Command
    module Db
      module System
        class ChangeCommand < Base # :nodoc:
          class_option :to, desc: "The database system to switch to."

          def initialize(positional_args, option_args, *)
            @argv = positional_args + option_args
            super
          end

          def perform
            require "rails/generators"
            require "rails/generators/rails/db/system/change/change_generator"
            Rails::Generators::Db::System::ChangeGenerator.start(@argv)
          end
        end
      end
    end
  end
end
