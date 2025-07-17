# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name          = "tl_linkoln_client"
  spec.version       = "0.1.4"
  spec.authors       = [ "Ha Dung" ]
  spec.email         = [ "h-dung@w.metroengines.jp" ]

  spec.summary       = "SC client for TlLinkoln integration"
  spec.description   = "SOAP-based client to integrate SC/TlLinkoln with HotelPricing module"
  spec.homepage      = "https://yourdomain.com"
  spec.license       = "MIT"

  spec.files         = Dir["lib/**/*.rb"]
  spec.require_paths = [ "lib" ]

  spec.required_ruby_version = '>= 2.7.0'

  spec.add_dependency "activesupport"
  spec.add_dependency "excon", '~> 0.71.0'
  spec.add_dependency "nokogiri"
  spec.add_dependency "ox"
  spec.add_dependency "savon"
  spec.metadata['rubygems_mfa_required'] = 'true'
end
