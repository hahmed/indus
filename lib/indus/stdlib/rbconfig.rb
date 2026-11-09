# RbConfig for compiled programs: the constants the pure-Ruby standard library reads at load time.
# (CRuby's rbconfig.rb is generated per installation; this is the compile-time host's view.)
module RbConfig
  CONFIG = {
    "host_os" => "darwin", "arch" => "arm64", "ruby_version" => "4.0.0", "EXEEXT" => "", "bindir" => "/usr/bin",
    "ruby_install_name" => "ruby", "RUBY_PROGRAM_VERSION" => "4.0", "libdir" => "/usr/lib", "rubylibdir" => "/usr/lib/ruby",
    "sitelibdir" => "/usr/lib/ruby/site_ruby", "DLEXT" => "bundle", "LIBEXT" => "a", "MAJOR" => "4", "MINOR" => "0", "TEENY" => "0",
  }
  def self.ruby = "/usr/bin/ruby"
end
