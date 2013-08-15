require "retsync/engine"

module Retsync
    
  # The location of the RETS login
  mattr_accessor :url
  @@url = nil

  # RETS username
  mattr_accessor :username
  @@username = nil
  
  # RETS password
  mattr_accessor :password
  @@password = nil 
  
  # When performing a large property import, how many days to search on per batch
  mattr_accessor :days_per_batch
  @@days_per_batch = 30
  
  # How many records to limit per request
  mattr_accessor :limit
  @@limit = 100
  
  # Only import active property listings
  mattr_accessor :import_only_active
  @@import_only_active  = true
  
  # Location for storing temp image files
  mattr_accessor :temp_path
  @@temp_path = '/tmp'
  
  # Location for storing image files locally
  mattr_accessor :image_path
  @@image_path = '/tmp'

end
