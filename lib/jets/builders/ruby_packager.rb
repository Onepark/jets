require "bundler" # for clean_old_submodules only

module Jets::Builders
  class RubyPackager
    include Util

    GEM_REGEXP = /-(arm|x)\d+.*-(darwin|linux)/

    attr_reader :full_app_root
    def initialize(relative_app_root)
      @full_app_root = "#{build_area}/#{relative_app_root}"
    end

    def install
      return unless gemfile_exist?

      clean_old_submodules
      bundle_install
      bundle_check
      copy_bundle_config
      copy_cache_gems
    end

    #   build gems in vendor/gems/ruby/2.5.0 (done in install phase)
    def finish
      return unless gemfile_exist?
      tidy
    end

    def gemfile_exist?
      gemfile_path = "#{@full_app_root}/Gemfile"
      File.exist?(gemfile_path)
    end

    # Installs gems on the current target system: both compiled and non-compiled.
    # If user is on a macosx machine, macosx gems will be installed.
    # If user is on a linux machine, linux gems will be installed.
    #
    # Copies Gemfile* to /tmp/jets/demo/cache folder and installs
    # gems with bundle install from there.
    #
    # We take the time to copy Gemfile and bundle into a separate directory
    # because it gets left around to act as a 'cache'.  So, when the builds the
    # project gets built again not all the gems from get installed from the
    # beginning.
    def bundle_install
      full_project_path = @full_app_root
      headline "Bundling: running bundle install in cache area: #{cache_area}."

      copy_gemfiles(full_project_path)
      copy_bundled_gems(full_project_path)

      # Uncomment out to always remove the cache/vendor/gems to debug
      # FileUtils.rm_rf("#{cache_area}/vendor/gems")

      # Remove .bundle folder so .bundle/config doesnt affect how Jets packages gems.
      # Not using BUNDLE_IGNORE_CONFIG=1 to allow home ~/.bundle/config to affect bundling though.
      # This is useful if you have private gems sources that require authentication. Example:
      #
      #    bundle config gems.myprivatesource.com user:pass
      #

      create_bundle_config
      require "bundler" # dynamically require bundler so user can use any bundler

      github_token = ENV['BUNDLE_GITHUB__COM']
      Bundler.with_unbundled_env do
        sh(
          "cd #{cache_area} && " \
          "env BUNDLE_GITHUB__COM=#{github_token} bundle install"
        )
      end
      create_bundle_config(frozen: true)

      rewrite_gemfile_lock("#{cache_area}/Gemfile.lock")

      # Copy the Gemfile.lock back to the project in case it was updated.
      # For example we add the jets-rails to the Gemfile.
      copy_back_gemfile_lock

      puts 'Bundle install completed'
    end

    # Example `bundle check` error:
    #
    #     The following gems are missing
    #     * date (3.3.3)
    #     * timeout (0.3.2)
    #     Install missing gems with `bundle install`
    #
    # Example success:
    #
    #     The Gemfile's dependencies are satisfied
    #
    def bundle_check
      out = ''
      Bundler.with_unbundled_env do
        out = `cd #{cache_area} && bundle check 2>&1`
      end
      if out.include?("missing")
        puts "Failed: bundle check".color(:red)
        puts <<~EOL
          This means something went wrong with the bundle install.
          Jets will prevent the deployment to AWS Lambda.
          It's better to error now instead of finding out on AWS Lambda.
          The bundle install can fail for different system-specific reasons.
          It could be an outdated or incompatible version of RubyGems and Ruby.

          Related: https://community.boltops.com/t/could-not-find-timeout-0-3-1-in-any-of-the-sources/996

        EOL
        exit 1
      end
    end

    def copy_back_gemfile_lock
      src = "#{cache_area}/Gemfile.lock"
      dest = "#{@full_app_root}/Gemfile.lock"
      FileUtils.cp(src, dest)
    end

    # Clean up extra unneeded files to reduce package size
    # Because we're removing files (something dangerous) use full paths.
    def tidy
      puts "Tidying project: removing ignored files to reduce package size."
      tidy_project(@full_app_root)
      # The rack sub project has it's own gitignore.
      tidy_project(@full_app_root+"/rack")
    end

    def tidy_project(path)
      Tidy.new(path).cleanup!
    end

    # When using submodules, bundler leaves old submodules behind. Over time this inflates
    # the size of the the cache gems.  So we'll clean it up.
    def clean_old_submodules
      # https://stackoverflow.com/questions/38800129/parsing-a-gemfile-lock-with-bundler
      lockfile = "#{cache_area}/Gemfile.lock"
      return unless File.exist?(lockfile)

      return if Bundler.bundler_major_version <= 1 # LockfileParser only works for Bundler version 2+

      parser = Bundler::LockfileParser.new(Bundler.read_file(lockfile))
      specs = parser.specs

      # specs = Bundler.load.specs
      # IE: spec.source.to_s: "https://github.com/tongueroo/webpacker.git (at jets@a8c4661)"
      submoduled_specs = specs.select do |spec|
        spec.source.to_s =~ /@\w+\)/
      end

      # find git shas to keep
      # IE: ["a8c4661", "abc4661"]
      git_shas = submoduled_specs.map do |spec|
        md = spec.source.to_s.match(/@(\w+)\)/)
        md[1] # git_sha
      end

      # IE: /tmp/jets/demo/cache/vendor/gems/ruby/2.5.0/bundler/gems/webpacker-a8c46614c675
      Dir.glob("#{cache_area}/vendor/gems/ruby/2.5.0/bundler/gems/*").each do |path|
        sha = path.split('-').last[0..6] # only first 7 chars of the git sha
        unless git_shas.include?(sha)
          # puts "Removing old submoduled gem: #{path}" # uncomment to see and debug
          FileUtils.rm_rf(path) # REMOVE old submodule directory
        end
      end
    end

    def copy_bundled_gems(full_project_path)
      src = "#{full_project_path}/bundled_gems"
      return unless File.exist?(src)
      Jets::Util.cp_r(src, "#{cache_area}/bundled_gems")
    end

    def copy_gemfiles(full_project_path)
      FileUtils.mkdir_p(cache_area)
      FileUtils.cp("#{full_project_path}/Gemfile", "#{cache_area}/Gemfile")

      gemfile_lock = "#{full_project_path}/Gemfile.lock"
      dest = "#{cache_area}/Gemfile.lock"
      return unless File.exist?(gemfile_lock)

      FileUtils.cp(gemfile_lock, dest)
    end

    # Remove the BUNDLED WITH line since we don't control the bundler gem version on AWS Lambda
    # And this can cause issues with require 'bundler/setup'
    def rewrite_gemfile_lock(gemfile_lock)
      lines = IO.readlines(gemfile_lock)

      # Remove BUNDLED WITH
      # amount is the number of lines to remove
      new_lines, capture, count, amount = [], true, 0, 2
      lines.each do |l|
        capture = false if l.include?('BUNDLED WITH')
        if capture
          new_lines << l
        end
        if capture == false
          count += 1
          capture = count > amount # renable capture
        end
      end

      # Replace things like nokogiri (1.11.1-x86_64-darwin) => nokogiri (1.11.1)
      lines, new_lines = new_lines, []
      lines.each do |l|
        l.sub!(GEM_REGEXP, '') if l =~ GEM_REGEXP
        new_lines << l
      end

      # Make sure platform is ruby
      lines, new_lines, in_platforms_section, platforms_rewritten = new_lines, [], false, false
      lines.each do |l|
        if in_platforms_section && platforms_rewritten # once PLATFORMS has been found, skip all lines until the next section
          if l.present?
            next
          else
            in_platforms_section = false
          end
        end

        if in_platforms_section && !platforms_rewritten # specify ruby as the only platform
          new_lines << "  ruby\n"
          platforms_rewritten = true
          next
        end

        in_platforms_section = l.include?('PLATFORMS')
        new_lines << l
      end

      content = new_lines.join('')
      IO.write(gemfile_lock, content)
    end

    def copy_bundle_config
      # Override project's .bundle/config and ensure that .bundle/config matches
      # at these 2 spots:
      #   app_root/.bundle/config
      #   vendor/gems/.bundle/config
      cache_bundle_config = "#{cache_area}/.bundle/config"
      app_bundle_config = "#{@full_app_root}/.bundle/config"
      FileUtils.mkdir_p(File.dirname(app_bundle_config))
      FileUtils.cp(cache_bundle_config, app_bundle_config)
    end

    # On circleci the "#{Jets.build_root}/.bundle/config" doesnt exist
    # this only happens with ssh debugging, not when the ci.sh script gets ran.
    # But on macosx it exists.
    # Dont know why this is the case.
    def create_bundle_config(frozen: false)
      FileUtils.rm_rf("#{cache_area}/.bundle")
      frozen_line = %Q|BUNDLE_FROZEN: "true"\n| if frozen
      text =<<-EOL
---
#{frozen_line}BUNDLE_PATH: "vendor/gems"
BUNDLE_WITHOUT: "development:test"
EOL
      bundle_config = "#{cache_area}/.bundle/config"
      FileUtils.mkdir_p(File.dirname(bundle_config))
      IO.write(bundle_config, text)
    end

    def copy_cache_gems
      vendor_gems = "#{@full_app_root}/vendor/gems"
      if File.exist?(vendor_gems)
        puts "Removing current vendor_gems from project"
        FileUtils.rm_rf(vendor_gems)
      end
      # Leave #{Jets.build_root}/vendor_gems behind to act as cache
      if File.exist?("#{cache_area}/vendor/gems")
        FileUtils.mkdir_p(File.dirname(vendor_gems))
        Jets::Util.cp_r("#{cache_area}/vendor/gems", vendor_gems)
      end
    end
  end
end
