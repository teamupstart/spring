require_relative "../../helper"
require 'spring/client'

class VersionTest < ActiveSupport::TestCase
  test "outputs current version number" do
    version = Spring::Client::Version.new 'version'

    out, _ = capture_io do
      version.call
    end

    assert_equal "Spring version #{Spring::VERSION}", out.chomp
  end
end
