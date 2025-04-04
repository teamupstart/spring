require "io/wait"
require "timeout"
require "spring/client"
require "active_support/core_ext/string/strip"

module Spring
  module Test
    class AcceptanceTest < ActiveSupport::TestCase
      runnables.delete self # prevent Minitest running this class

      DEFAULT_SPEEDUP = 0.8

      def rails_version
        if ENV['RAILS_VERSION'] == "edge"
          ">= 8.0.0.alpha"
        else
          "~> #{ENV['RAILS_VERSION'] || "7.1"}.0"
        end
      end

      # Extension point for spring-watchers-listen
      def generator_klass
        Spring::Test::ApplicationGenerator
      end

      def generator
        @@generator ||= generator_klass.new(rails_version)
      end

      def app
        @app ||= Spring::Test::Application.new("#{Spring::Test.root}/apps/tmp")
      end

      def spring_env
        app.spring_env
      end

      def assert_output(artifacts, expected)
        expected.each do |stream, output|
          assert_match output, artifacts[stream],
            "expected #{stream} to include #{output.inspect}.\n\n#{app.debug(artifacts)}"
        end
      end

      def assert_success(command, expected_output = nil)
        artifacts = app.run(*Array(command))
        assert artifacts[:status].success?, "expected successful exit status\n\n#{app.debug(artifacts)}"
        assert_output artifacts, expected_output if expected_output
      end

      def assert_failure(command, expected_output = nil)
        artifacts = app.run(*Array(command))
        assert !artifacts[:status].success?, "expected unsuccessful exit status\n\n#{app.debug(artifacts)}"
        assert_output artifacts, expected_output if expected_output
      end

      def refute_output_includes(command, not_expected)
        artifacts = app.run(*Array(command))
        not_expected.each do |stream, output|
          assert !artifacts[stream].include?(output),
                 "expected #{stream} to not include '#{output}'.\n\n#{app.debug(artifacts)}"
        end
      end

      def assert_speedup(ratio = DEFAULT_SPEEDUP)
        if ENV['CI']
          yield
        else
          app.with_timing do
            yield
            assert app.timing_ratio < ratio, "#{app.last_time} was not less than #{ratio} of #{app.first_time}"
          end
        end
      end

      def without_gem(name)
        gem_home = app.gem_home.join('gems')
        FileUtils.mv(gem_home.join(name), app.root)
        yield
      ensure
        FileUtils.mv(app.root.join(name), gem_home)
      end

      setup do
        generator.generate_if_missing
        generator.install_spring
        generator.copy_to(app.root)
      end

      teardown do
        app.stop_spring
      end

      test "basic" do
        assert_speedup do
          2.times { app.run app.spring_test_command }
        end
      end

      test "crash on boot" do
        app.run app.spring_test_command, env: {
          "CRASH_ON_BOOT" => "1",
          # If the command is small enough, it might fit in the socket buffer and writing the command won't block.
          # So we send a big environment variable to better reproduce the problem.
          "FOO" => "bar" * 4_000,
      }
      end

      test "help message when called without arguments" do
        assert_success "bin/spring", stdout: 'Usage: spring COMMAND [ARGS]'
        assert spring_env.server_running?
      end

      test "shows help" do
        assert_success "bin/spring help", stdout: 'Usage: spring COMMAND [ARGS]'
        assert_success "bin/spring -h", stdout: 'Usage: spring COMMAND [ARGS]'
        assert_success "bin/spring --help", stdout: 'Usage: spring COMMAND [ARGS]'
        refute spring_env.server_running?
      end

      test "tells the user that Spring is being used when used automatically via binstubs" do
        assert_success "bin/rails runner ''", stderr: "Running via Spring preloader in process"
        assert_success app.spring_test_command, stderr: "Running via Spring preloader in process"
      end

      test "does not tell the user that Spring is being used when quiet is enabled via Spring.quiet" do
        File.write("#{app.user_home}/.spring.rb", "Spring.quiet = true")
        assert_success "bin/rails runner ''"
        refute_output_includes "bin/rails runner ''", stderr: 'Running via Spring preloader in process'
      end

      test "does not tell the user that Spring is being used when quiet is enabled via SPRING_QUIET ENV var" do
        assert_success "SPRING_QUIET=true bin/rails runner ''"
        refute_output_includes "bin/rails runner ''", stderr: 'Running via Spring preloader in process'
      end

      test "raises if config.cache_classes is true" do
        config_path = app.path("config/environments/development.rb")
        config = File.read(config_path)
        if config.include?("config.cache_classes")
          config.sub!(/config\.cache_classes\s*=\s*false/, "config.cache_classes = true")
        else # 7.1+ doesn't have config.cache_classes in the config at all
          config.sub!(/config.enable_reloading = true/, "config.enable_reloading = true\nconfig.cache_classes = true")
        end
        File.write(config_path, config)

        assert_failure "bin/rails runner 1", stderr: "Please, set config.cache_classes to false"
      end

      test "test changes are picked up" do
        assert_speedup do
          assert_success app.spring_test_command, stdout: "0 failures"

          app.insert_into_test "raise 'omg'"
          assert_failure app.spring_test_command, stdout: "RuntimeError: omg"
        end
      end

      test "code changes are picked up" do
        assert_speedup do
          assert_success app.spring_test_command, stdout: "0 failures"

          File.write(app.controller, app.controller.read.sub("@posts = Post.all", "raise 'omg'"))
          assert_failure app.spring_test_command, stdout: "RuntimeError: omg"
        end
      end

      test "code changes in pre-referenced app files are picked up" do
        File.write(app.path("config/initializers/load_posts_controller.rb"), "Rails.application.config.to_prepare { PostsController }\n")

        assert_speedup do
          assert_success app.spring_test_command, stdout: "0 failures"

          File.write(app.controller, app.controller.read.sub("@posts = Post.all", "raise 'omg'"))
          assert_failure app.spring_test_command, stdout: "RuntimeError: omg"
        end
      end

      test "app gets reloaded when preloaded files change" do
        assert_success app.spring_test_command

        File.write(app.application_config, app.application_config.read + <<-RUBY.strip_heredoc)
          class Foo
            def self.omg
              raise "omg"
            end
          end
        RUBY
        app.insert_into_test "Foo.omg"

        app.await_reload
        assert_failure app.spring_test_command, stdout: "RuntimeError: omg", log: /child \d+ shutdown/
      end

      test "app gets reloaded even with a ton of boot output" do
        limit = UNIXSocket.pair.first.getsockopt(:SOCKET, :SNDBUF).int

        assert_success app.spring_test_command
        File.write(app.path("config/initializers/verbose.rb"), "#{limit}.times { puts 'x' }")

        app.await_reload
        assert_success app.spring_test_command
      end

      test "app gets reloaded even with abort_on_exception=true" do
        assert_success app.spring_test_command
        File.write(app.path("config/initializers/thread_config.rb"), "Thread.abort_on_exception = true")

        app.await_reload
        assert_success app.spring_test_command
      end

      test "app recovers when a boot-level error is introduced" do
        config = app.application_config.read

        assert_success app.spring_test_command

        File.write(app.application_config, "#{config}\nomg")
        app.await_reload

        assert_failure app.spring_test_command

        File.write(app.application_config, config)
        assert_success app.spring_test_command
      end

      test "stop command kills server" do
        app.run app.spring_test_command
        assert spring_env.server_running?, "The server should be running but it isn't"

        assert_success "bin/spring stop"
        assert !spring_env.server_running?, "The server should not be running but it is"
      end

      test "custom commands" do
        # Start spring before setting up the command, to test that it gracefully upgrades itself
        assert_success "bin/rails runner ''"

        File.write(app.spring_config, <<-RUBY.strip_heredoc)
          class CustomCommand
            def call
              puts "omg"
            end

            def exec_name
              "rake"
            end
          end

          Spring.register_command "custom", CustomCommand.new
        RUBY

        assert_success "bin/spring custom", stdout: "omg"

        assert_success "bin/spring binstub custom"
        assert_success "bin/custom", stdout: "omg"

        app.env["DISABLE_SPRING"] = "1"
        assert_success %{bin/custom -e 'puts "foo"'}, stdout: "foo"
      end

      test "binstub" do
        assert_success "bin/rails server --help", stdout: /Usage:\s+(bin\/)?rails server/ # rails command fallback

        assert_success "#{app.spring} binstub rake", stdout: "bin/rake: Spring already present"

        assert_success "#{app.spring} binstub --remove rake", stdout: "bin/rake: Spring removed"
        assert !app.path("bin/rake").read.include?(Spring::Client::Binstub::LOADER)
        assert_success "bin/rake -T", stdout: "rake db:migrate"

        assert_success "#{app.spring} binstub rake", stdout: "bin/rake: Spring inserted"
        assert app.path("bin/rake").read.include?(Spring::Client::Binstub::LOADER)
      end

      test "binstub remove all" do
        assert_success "bin/spring binstub --remove --all"
        refute File.exist?(app.path("bin/spring"))
      end

      test "binstub when spring gem is missing" do
        without_gem "spring-#{Spring::VERSION}" do
          File.write(app.gemfile, app.gemfile.read.gsub(/gem 'spring.*/, ""))
          app.run! "bundle install", timeout: 300
          assert_success "bin/rake -T", stdout: "rake db:migrate"
        end
      end

      test "binstub when spring binary is missing" do
        begin
          File.rename(app.path("bin/spring"), app.path("bin/spring.bak"))
          assert_failure "bin/rake -T", stderr: "`load': cannot load such file"
        ensure
          File.rename(app.path("bin/spring.bak"), app.path("bin/spring"))
        end
      end

      test "binstub preserve magic comments" do
        File.write(app.path("bin/rake"), <<-RUBY.strip_heredoc)
          #!/usr/bin/env ruby
          # frozen_string_literal: true
          #
          # more comments
          require 'bundler/setup'
          load Gem.bin_path('rake', 'rake')
        RUBY

        assert_success "bin/spring binstub rake"

        expected = <<-RUBY.gsub(/^          /, "")
          #!/usr/bin/env ruby
          # frozen_string_literal: true
          #
          # more comments
          #{Spring::Client::Binstub::LOADER.strip}
          require 'bundler/setup'
          load Gem.bin_path('rake', 'rake')
        RUBY
        assert_equal expected, app.path("bin/rake").read
      end

      test "binstub upgrade with old binstub" do
        File.write(app.path("bin/rake"), <<-RUBY.strip_heredoc)
          #!/usr/bin/env ruby

          if !Process.respond_to?(:fork) || Gem::Specification.find_all_by_name("spring").empty?
            exec "bundle", "exec", "rake", *ARGV
          else
            ARGV.unshift "rake"
            load Gem.bin_path("spring", "spring")
          end
        RUBY

        File.write(app.path("bin/rails"), <<-RUBY.strip_heredoc)
          #!/usr/bin/env ruby

          if !Process.respond_to?(:fork) || Gem::Specification.find_all_by_name("spring").empty?
            APP_PATH = File.expand_path('../../config/application',  __FILE__)
            require_relative '../config/boot'
            require 'rails/commands'
          else
            ARGV.unshift "rails"
            load Gem.bin_path("spring", "spring")
          end
        RUBY

        assert_success "bin/spring binstub --all", stdout: "upgraded"

        expected = <<-RUBY.gsub(/^          /, "")
          #!/usr/bin/env ruby
          #{Spring::Client::Binstub::LOADER.strip}
          require 'bundler/setup'
          load Gem.bin_path('rake', 'rake')
        RUBY
        assert_equal expected, app.path("bin/rake").read

        expected = <<-RUBY.gsub(/^          /, "")
          #!/usr/bin/env ruby
          #{Spring::Client::Binstub::LOADER.strip}
          APP_PATH = File.expand_path('../../config/application',  __FILE__)
          require_relative '../config/boot'
          require 'rails/commands'
        RUBY
        assert_equal expected, app.path("bin/rails").read
      end

      test "binstub upgrade with new binstub variations" do
        expected = <<-RUBY.gsub(/^          /, "")
          #!/usr/bin/env ruby
          #{Spring::Client::Binstub::LOADER.strip}
          require 'bundler/setup'
          load Gem.bin_path('rake', 'rake')
        RUBY

        # older variation with double quotes
        File.write(app.path("bin/rake"), <<-RUBY.strip_heredoc)
          #!/usr/bin/env ruby
          begin
            load File.expand_path("../spring", __FILE__)
          rescue LoadError
          end
          require 'bundler/setup'
          load Gem.bin_path('rake', 'rake')
        RUBY

        assert_success "bin/spring binstub rake", stdout: "bin/rake: upgraded"
        assert_equal expected, app.path("bin/rake").read

        # newer variation with single quotes
        File.write(app.path("bin/rake"), <<-RUBY.strip_heredoc)
          #!/usr/bin/env ruby
          begin
            load File.expand_path('../spring', __FILE__)
          rescue LoadError
          end
          require 'bundler/setup'
          load Gem.bin_path('rake', 'rake')
        RUBY

        assert_success "bin/spring binstub rake", stdout: "bin/rake: upgraded"
        assert_equal expected, app.path("bin/rake").read

        # newer variation which checks end of exception message
        File.write(app.path("bin/rake"), <<-RUBY.strip_heredoc)
          #!/usr/bin/env ruby
          begin
            spring_bin_path = File.expand_path('../spring', __FILE__)
            load spring_bin_path
          rescue LoadError => e
            raise unless e.message.end_with? spring_bin_path, 'spring/binstub'
          end
          require 'bundler/setup'
          load Gem.bin_path('rake', 'rake')
        RUBY

        assert_success "bin/spring binstub rake", stdout: "bin/rake: upgraded"
        assert_equal expected, app.path("bin/rake").read

        # newer variation which checks end of exception message using include
        File.write(app.path("bin/rake"), <<-RUBY.strip_heredoc)
          #!/usr/bin/env ruby
          begin
            load File.expand_path('../spring', __FILE__)
          rescue LoadError => e
            raise unless e.message.include?('spring')
          end
          require 'bundler/setup'
          load Gem.bin_path('rake', 'rake')
        RUBY

        assert_success "bin/spring binstub rake", stdout: "bin/rake: upgraded"
        assert_equal expected, app.path("bin/rake").read
      end

      test "binstub remove with new binstub variations which checks end of the exception message using include" do
        # newer variation which checks end of exception message using include
        File.write(app.path("bin/rake"), <<-RUBY.strip_heredoc)
          #!/usr/bin/env ruby
          begin
            load File.expand_path('../spring', __FILE__)
          rescue LoadError => e
            raise unless e.message.include?('spring')
          end
          require 'bundler/setup'
          load Gem.bin_path('rake', 'rake')
        RUBY

        File.write(app.path("bin/rails"), <<-RUBY.strip_heredoc)
          #!/usr/bin/env ruby
          begin
            load File.expand_path('../spring', __FILE__)
          rescue LoadError => e
            raise unless e.message.include?('spring')
          end
          APP_PATH = File.expand_path('../../config/application',  __FILE__)
          require_relative '../config/boot'
          require 'rails/commands'
        RUBY

        assert_success "bin/spring binstub --remove rake", stdout: "bin/rake: Spring removed"
        assert_success "bin/spring binstub --remove rails", stdout: "bin/rails: Spring removed"

        expected = <<-RUBY.strip_heredoc
          #!/usr/bin/env ruby
          require 'bundler/setup'
          load Gem.bin_path('rake', 'rake')
        RUBY
        assert_equal expected, app.path("bin/rake").read

        expected = <<-RUBY.strip_heredoc
          #!/usr/bin/env ruby
          APP_PATH = File.expand_path('../../config/application',  __FILE__)
          require_relative '../config/boot'
          require 'rails/commands'
        RUBY
        assert_equal expected, app.path("bin/rails").read
      end

      test "binstub remove with new binstub variations" do
        # older variation with double quotes
        File.write(app.path("bin/rake"), <<-RUBY.strip_heredoc)
          #!/usr/bin/env ruby
          begin
            load File.expand_path("../spring", __FILE__)
          rescue LoadError
          end
          require 'bundler/setup'
          load Gem.bin_path('rake', 'rake')
        RUBY

        # newer variation with single quotes
        File.write(app.path("bin/rails"), <<-RUBY.strip_heredoc)
          #!/usr/bin/env ruby
          begin
            load File.expand_path('../spring', __FILE__)
          rescue LoadError
          end
          APP_PATH = File.expand_path('../../config/application',  __FILE__)
          require_relative '../config/boot'
          require 'rails/commands'
        RUBY

        assert_success "bin/spring binstub --remove rake", stdout: "bin/rake: Spring removed"
        assert_success "bin/spring binstub --remove rails", stdout: "bin/rails: Spring removed"

        expected = <<-RUBY.strip_heredoc
          #!/usr/bin/env ruby
          require 'bundler/setup'
          load Gem.bin_path('rake', 'rake')
        RUBY
        assert_equal expected, app.path("bin/rake").read

        expected = <<-RUBY.strip_heredoc
          #!/usr/bin/env ruby
          APP_PATH = File.expand_path('../../config/application',  __FILE__)
          require_relative '../config/boot'
          require 'rails/commands'
        RUBY
        assert_equal expected, app.path("bin/rails").read
      end

      test "after fork callback" do
        File.write(app.spring_config, "Spring.after_fork { puts '!callback!' }")
        assert_success "bin/rails runner 'puts 2'", stdout: "!callback!\n2"
      end

      test "global config file evaluated" do
        File.write("#{app.user_home}/.spring.rb", "Spring.after_fork { puts '!callback!' }")
        assert_success "bin/rails runner 'puts 2'", stdout: "!callback!\n2"
      end

      test "can define client tasks" do
        File.write("#{app.spring_client_config}", <<-RUBY)
          Spring::Client::COMMANDS["foo"] = lambda { |args| puts "bar -- \#{args.inspect}" }
        RUBY
        assert_success "bin/spring foo --baz", stdout: "bar -- [\"foo\", \"--baz\"]\n"
      end

      test "missing config/application.rb" do
        app.application_config.delete
        assert_failure "bin/rake -T", stderr: "unable to find your config/application.rb"
      end

      test "piping with boot-level error" do
        config = app.application_config.read
        File.write(app.application_config, "#{config}\nomg")
        assert_success "bin/rake -T | cat"
      end

      test "piping" do
        assert_success "bin/rake -T | grep db", stdout: "rake db:migrate"
      end

      test "status" do
        assert_success "bin/spring status", stdout: "Spring is not running"
        assert_success "bin/rails runner ''"
        assert_success "bin/spring status", stdout: "Spring is running"
      end

      test "runner command sets Rails environment from command-line options" do
        assert_success "bin/rails runner -e test 'puts Rails.env'", stdout: "test"
        assert_success "bin/rails runner --environment=test 'puts Rails.env'", stdout: "test"
      end

      test "forcing rails env via environment variable" do
        app.env['RAILS_ENV'] = 'test'
        assert_success "bin/rake -p 'Rails.env'", stdout: "test"
      end

      test "setting env vars with rake" do
        File.write(app.path("lib/tasks/env.rake"), <<-RUBY.strip_heredoc)
          task :print_rails_env => :environment do
            puts Rails.env
          end

          task :print_env do
            ENV.each { |k, v| puts "\#{k}=\#{v}" }
          end

          task(:default).clear.enhance [:print_rails_env]
        RUBY

        assert_success "bin/rake RAILS_ENV=test print_rails_env", stdout: "test"
        assert_success "bin/rake FOO=bar print_env", stdout: "FOO=bar"
        assert_success "bin/rake", stdout: "test"
      end

      test "changing the Gemfile works" do
        assert_success %(bin/rails runner 'require "sqlite3"')

        File.write(app.gemfile, app.gemfile.read.gsub(%r{gem ['"]sqlite3['"]}, %{# gem "sqlite3"}))
        app.await_reload

        assert_failure %(bin/rails runner 'require "sqlite3"'), stderr: "sqlite3"
      end

      test "changing the gems.rb works" do
        FileUtils.mv(app.gemfile, app.gems_rb)
        FileUtils.mv(app.gemfile_lock, app.gems_locked)

        assert_success %(bin/rails runner 'require "sqlite3"')

        File.write(app.gems_rb, app.gems_rb.read.gsub(%r{gem ['"]sqlite3['"]}, %{# gem "sqlite3"}))
        app.await_reload

        assert_failure %(bin/rails runner 'require "sqlite3"'), stderr: "sqlite3"
      end

      test "changing the Gemfile works when Spring calls into itself" do
        File.write(app.path("script.rb"), <<-RUBY.strip_heredoc)
          gemfile = Rails.root.join("Gemfile")
          File.write(gemfile, "\#{gemfile.read}gem 'text'\\n")
          Bundler.with_unbundled_env do
            system(#{app.env.inspect}, "bundle install")
          end
          output = `\#{Rails.root.join('bin/rails')} runner 'require "text"; puts "done";'`
          exit output.include? "done\n"
        RUBY

        assert_success [%(bin/rails runner 'load Rails.root.join("script.rb")'), timeout: 60]
      end

      test "changing the gems.rb works when spring calls into itself" do
        FileUtils.mv(app.gemfile, app.gems_rb)
        FileUtils.mv(app.gemfile_lock, app.gems_locked)

        File.write(app.path("script.rb"), <<-RUBY.strip_heredoc)
          gemfile = Rails.root.join("gems.rb")
          File.write(gemfile, "\#{gemfile.read}gem 'text'\\n")
          Bundler.with_unbundled_env do
            system(#{app.env.inspect}, "bundle install")
          end
          output = `\#{Rails.root.join('bin/rails')} runner 'require "text"; puts "done";'`
          exit output.include? "done\n"
        RUBY

        assert_success [%(bin/rails runner 'load Rails.root.join("script.rb")'), timeout: 60]
      end

      test "changing the environment between runs" do
        File.write(app.application_config, "#{app.application_config.read}\nENV['BAR'] = 'bar'")

        app.env["OMG"] = "1"
        app.env["FOO"] = "1"
        app.env["RUBYOPT"] = "-rrubygems"

        assert_success %(bin/rails runner 'p ENV["OMG"]'), stdout: "1"
        assert_success %(bin/rails runner 'p ENV["BAR"]'), stdout: "bar"
        assert_success %(bin/rails runner 'p ENV.key?("BUNDLE_GEMFILE")'), stdout: "true"
        assert_success %(bin/rails runner 'p ENV["RUBYOPT"]'), stdout: "bundler"

        app.env["OMG"] = "2"
        app.env.delete "FOO"

        assert_success %(bin/rails runner 'p ENV["OMG"]'), stdout: "2"
        assert_success %(bin/rails runner 'p ENV.key?("FOO")'), stdout: "false"
      end

      test "Kernel.raise remains private" do
        expr = "p Kernel.private_instance_methods.include?(:raise)"
        assert_success %(bin/rails runner '#{expr}'), stdout: "true"
      end

      test "custom bundle path" do
        skip if Gem::Version.new(RUBY_VERSION) < Gem::Version.new("3.1.0") && ENV["RAILS_VERSION"] == "7.0"

        bundle_path = app.path(".bundle/#{Bundler.ruby_scope}")
        bundle_path.dirname.mkpath

        FileUtils.cp_r "#{app.gem_home}/", bundle_path.to_s

        app.run! "bundle install --path .bundle --local"

        assert_speedup do
          2.times { assert_success "bundle exec rails runner ''" }
        end
      end

      test "booting a foreground server" do
        FileUtils.cd(app.root) do
          assert !spring_env.server_running?
          assert_success "bin/spring server &"

          Timeout.timeout(10) do
            sleep 0.1 until spring_env.server_running? && spring_env.socket_path.exist?
          end

          assert_success app.spring_test_command
        end
      end

      test "server boot timeout" do
        app.env["SPRING_SERVER_COMMAND"] = "sleep 1"
        File.write("#{app.spring_client_config}", %(
          Spring.boot_timeout = 0.1
        ))

        assert_failure "bin/rails runner ''", stderr: "timed out"
      end

      test "no warnings are shown for unsprung commands" do
        app.env["DISABLE_SPRING"] = "1"
        refute_output_includes "bin/rails runner ''", stderr: "WARN"
      end

      test "rails without arguments" do
        assert_success "bin/rails"
      end

      test "rails db:migrate" do
        assert_speedup do
          2.times { app.run "bin/rails db:migrate" }
        end
      end

      test "rails db:system:change" do
        assert_success "bin/rails db:system:change --to=sqlite3"
      end

      test "watches embedded engine initializers" do
        app.path("config/application.rb").write(<<~RUBY, mode: "a+")

          $LOAD_PATH << Pathname.new(__dir__).join("../engine/lib").realpath.to_s
          require "my_engine"
        RUBY
        engine_lib = app.path("engine/lib/my_engine.rb")
        engine_lib.dirname.mkpath
        engine_lib.write(<<~RUBY)
          require "rails/engine"

          class MyEngine < Rails::Engine
          end
        RUBY
        engine_initializer = app.path("engine/config/initializers/one.rb")
        engine_initializer.dirname.mkpath
        engine_initializer.write("")

        assert_success app.spring_test_command

        engine_initializer.write("raise 'omg'")

        assert_failure app.spring_test_command, stderr: "omg (RuntimeError)"
      end
    end
  end
end
