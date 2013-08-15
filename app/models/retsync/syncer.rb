require 'ruby-rets'
require 'httparty'
require 'json'

#
# Check for examples:
# http://rets.solidearth.com/ClientHome.aspx
# https://www.flexmls.com/developers/rets/tutorials/dmql-tutorial/
# https://www.flexmls.com/developers/rets/tutorials/how-to-efficiently-replicate-rets-data/
#

class RetsImporter # < ActiveRecord::Base
   
  @@rets_client = nil
  @@config = nil
  @@query_types = {
    'RES' => 'residential',
    'COM' => 'commercial',
    'LND' => 'land'
  }

  def self.config
    return @@config
  end
    
  def self.get_config
    @@config = {
      'url'                 => nil, # URL to the RETS login
      'username'            => nil,
      'password'            => nil,
      'limit'               => nil, # How many records to limit per request
      'days_per_batch'      => nil, # When performing a large property import, how many days to search on per batch
      'import_only_active'  => nil, # Only import active property listings 
      'image_path'          => nil, # Where property images are stored
      'temp_path'           => nil,
      'log_file'            => nil
    }
    config = YAML::load(File.open("#{Rails.root}/config/rets_importer.yml"))
    config = config[ENV['RAILS_ENV']]
    config.each { |key,val| @@config[key] = val }
  end
  
  def self.client
    self.get_config if @@config.nil? || @@config['url'].nil?
        
    if (@@rets_client.nil?)     
      @@rets_client = RETS::Client.login(
        :url      => @@config['url'],
        :username => @@config['username'],
        :password => @@config['password']
      )
    end
    return @@rets_client
  end
  
  def self.update_all(last_updated = nil)
    self.get_config if @@config.nil? || @@config['url'].nil?
    
    s = nil
    if last_updated.nil?
      if !Caboose::Setting.exists?(:name => 'rets_last_updated')
        Caboose::Setting.create(:name => 'rets_last_updated', :value => '2013-08-06T00:00:01')
      end
      s = Caboose::Setting.where(:name => 'rets_last_updated').first
      last_updated = DateTime.parse(s.value)
    else
      last_updated = DateTime.parse(last_updated)  
    end    
    
    self.import_properties_modified_after(last_updated, 'RES')
    self.import_properties_modified_after(last_updated, 'COM')
    self.import_properties_modified_after(last_updated, 'LND')
    self.import_agents_modified_after(last_updated)
    self.update_residential_images_after(last_updated)
    self.update_commercial_images_after(last_updated)
    self.update_land_images_after(last_updated)
    
    if !s.nil?
      s.value = DateTime.now.strftime('%FT%T')
      s.save
    end
  end

  #=============================================================================
  # Properties
  #=============================================================================
  
  #def self.import_properties_created_after(date_created, type = 'RES')
  #  d = date_created
  #  while d.strftime('%F') <= DateTime.now.strftime('%F') do      
  #    break if d.nil?
  #  
  #    d2 = d.strftime('%FT%T')
  #    d2 << "-"
  #    d2 << (d+@@config['days_per_batch']).strftime('%FT%T')
  #    
  #    query = "(DATE_CREATED=#{d2})"
  #    query << ",(STATUS=A)" if @@config['import_only_active']      
  #    self.import_properties(query, type)
  #    
  #    d = d + @@config['days_per_batch']
  #  end
  #end
  
  def self.import_properties_modified_after(date_modified, type = 'RES')
    d = date_modified
    while d.strftime('%FT%T') <= DateTime.now.strftime('%FT%T') do      
      break if d.nil?
    
      d2 = d.strftime('%FT%T')
      d2 << "-"
      d2 << (d+@@config['days_per_batch']).strftime('%FT%T')
      
      query = "(DATE_MODIFIED=#{d2})"
      query << ",(STATUS=A)" if @@config['import_only_active']      
      self.import_properties(query, type)
      
      d = d + @@config['days_per_batch']
    end
  end
  
  def self.import_properties(query, type = 'RES')
    # See how many records we have
    self.client.search(
      :search_type => 'Property',
      :class => type,
      :query => query,
      :count_mode => :only,
      :timeout => -1,
    )
    # Return if no records found
    if (self.client.rets_data[:code] == "20201")
      self.log "No " + @@query_types[type] + " properties found for query: #{query}"
      return
    else
      count = self.client.rets_data[:count]            
      self.log "Importing #{count} " + @@query_types[type] + " " + (count == 1 ? "property" : "properties") + "..."
    end

    count = self.client.rets_data[:count]    
    batch_count = (count.to_f/@@config['limit'].to_f).ceil
    
    (0...batch_count).each do |i|  
      params = {
        :search_type => 'Property',
        :class => type,
        :query => query,
        :limit => @@config['limit'],
        :offset => @@config['limit'] * i,
        :timeout => -1
      }
      self.client.search(params) do |data|
        p = nil        
        if (type == 'RES')
          p = ResidentialProperty.where(:mls_acct => data['MLS_ACCT']).first
          p = ResidentialProperty.new if p.nil?             
        elsif (type == 'COM')
          p = CommercialProperty.where(:mls_acct => data['MLS_ACCT']).first
          p = CommercialProperty.new if p.nil?
        elsif (type == 'LND')
          p = LandProperty.where(:mls_acct => data['MLS_ACCT']).first
          p = LandProperty.new if p.nil?
        end
        p.parse(data)
        p.id = p.mls_acct.to_i
        p.save
      end      
    end
  end
  
  def self.import_property(mls_acct, type = 'RES')
    self.get_config if @@config.nil? || @@config['url'].nil?
    params = {
      :search_type => 'Property',
      :class => type,
      :query => "(MLS_ACCT=#{mls_acct})",
      :limit => @@config['limit'],
      :offset => 0,
      :timeout => -1
    }
    p = nil
    self.client.search(params) do |data|      
      if (type == 'RES')
        p = ResidentialProperty.where(:mls_acct => data['MLS_ACCT']).first
        p = ResidentialProperty.new if p.nil?
      elsif (type == 'COM')
        p = CommercialProperty.where(:mls_acct => data['MLS_ACCT']).first
        p = CommercialProperty.new if p.nil?
      elsif (type == 'LND')
        p = LandProperty.where(:mls_acct => data['MLS_ACCT']).first
        p = LandProperty.new if p.nil?
      end
      p.parse(data)
      p.id = p.mls_acct.to_i
      p.save   
    end
  
    if (type == 'RES')
      self.update_residential_images(p)
    elsif (type == 'COM')
      self.update_commercial_images(p)
    elsif (type == 'LND')
      self.update_land_images(p)
    end
    
    if (type == 'RES')
      self.update_residential_coords(p)
    elsif (type == 'COM')
      self.update_commercial_coords(p)
    elsif (type == 'LND')
      self.update_land_coords(p)
    end
  end
  
  #=============================================================================
  # Agents
  #=============================================================================
  
  def self.import_agents_modified_after(date_modified)
    
    d = date_modified.strftime('%FT%T')
    d << "-"
    d << DateTime.now.strftime('%FT%T')
    query = "(LA_DATE_MODIFIED=#{d}),(LA_MEMBER_STATUS=A)"
          
    # See how many records we have
    self.client.search(
      :search_type => 'Agent',
      :class => 'AGT',
      :query => query,      
      :count_mode => :only,
      :timeout => -1
    )
    # Return if no records found
    if (self.client.rets_data[:code] == "20201")
      self.log "No agents found for query: #{query}"
      return
    end

    count = self.client.rets_data[:count]
    self.log "Handling #{count} agent records..."
    batch_count = (count.to_f/@@config['limit'].to_f).ceil
    
    (0...batch_count).each do |i|  
      params = {
        :search_type => 'Agent',
        :class => 'AGT',
        :query => query,
        :limit => @@config['limit'],
        :offset => @@config['limit'] * i,
        :timeout => -1
      }
      a = nil
      self.client.search(params) do |data|
        a = Agent.where(:la_code => data['LA_LA_CODE']).first
        a = Agent.new if a.nil?
        a.parse(data)
        a.save   
      end
      if (DateTime.parse(a.photo_date_modified) > date_modified)
        self.update_agent_images(a)
      end
    end
  end
                  
  def self.import_agent(la_code)    
    params = {
      :search_type => 'Agent',
      :class => 'AGT',
      :query => "(LA_MEMBER_STATUS=A),(LA_LA_CODE=#{la_code})",
      :limit => 1,
      :offset => 0,
      :timeout => -1
    }
    a = nil
    self.client.search(params) do |data|
      a = Agent.where(:la_code => data['LA_LA_CODE']).first
      a = Agent.new if a.nil?
      a.parse(data)
      a.save
    end
    
    self.update_agent_images(a)       
  end
  
  #=============================================================================
  # Images
  #=============================================================================
  
  def self.update_residential_images_after(date_modified)    
    count = ResidentialProperty.where("photo_date_modified > ?", date_modified.strftime('%FT%T')).count
    i = 1
    ResidentialProperty.where("photo_date_modified > ?", date_modified.strftime('%FT%T')).reorder(:mls_acct).all.each do |p|
      self.log "Updating images for #{i} of #{count} residential properties..."      
      self.update_residential_images(p)
      i = i + 1
    end
  end
  
  def self.update_commercial_images_after(date_modified)
    count = CommercialProperty.where( "photo_date_modified > ?", date_modified.strftime('%FT%T')).count
    i = 1
    CommercialProperty.where( "photo_date_modified > ?", date_modified.strftime('%FT%T')).reorder(:mls_acct).all.each do |p|
      self.log "Updating images for #{i} of #{count} commercial properties..."
      self.update_commercial_images(p)
    end
  end
  
  def self.update_land_images_after(date_modified)
    count = LandProperty.where("photo_date_modified > ?", date_modified.strftime('%FT%T')).count
    i = 1
    LandProperty.where("photo_date_modified > ?", date_modified.strftime('%FT%T')).reorder(:mls_acct).all.each do |p|
      self.log "Updating images for #{i} of #{count} land properties..."
      self.update_land_images(p)
    end
  end
    
  def self.update_residential_images(p)      
    # Delete all the images from amazon for this property
    self.log "-- Removing existing images for residential property #{p.mls_acct}..."
    p.residential_images.each do |img|
      img.image.destroy
      img.destroy
    end
    
    # Add them back
    self.log "-- Saving images for residential property #{p.mls_acct}..."
    self.client.get_object(:resource => :Property, :type => :Photo, :location => false, :id => p.mls_acct) do |headers, content|
    
      filename = "#{p.mls_acct}_#{headers['object-id']}.jpg"
    
      # Save the file to a temp location
      File.open("#{Rails.root}/tmp/#{p.mls_acct}_#{headers['object-id']}.jpg", 'wb') do |f|
        f.write(content)
      end
      
      # Open it back up and save it to amazon
      File.open("#{Rails.root}/tmp/#{p.mls_acct}_#{headers['object-id']}.jpg", 'r') do |f|        
        img = ResidentialImage.new
        img.residential_property_id = p.id
        img.sort_order = headers['object-id']
        img.image = f
        img.save
      end
      
      # Delete the local copy
      File.delete("#{Rails.root}/tmp/#{p.mls_acct}_#{headers['object-id']}.jpg")                
    end
  end
    
  def self.update_commercial_images(p)
    self.log "Saving images for commercial property #{p.mls_acct}..."
    self.client.get_object(:resource => :Property, :type => :Photo, :location => false, :id => p.mls_acct) do |headers, content|
    
      filename = "#{p.mls_acct}_#{headers['object-id']}.jpg"
    
      # Save the file to a temp location
      File.open("#{Rails.root}/tmp/#{p.mls_acct}_#{headers['object-id']}.jpg", 'wb') do |f|
        f.write(content)
      end
      
      # Open it back up and save it to amazon
      File.open("#{Rails.root}/tmp/#{p.mls_acct}_#{headers['object-id']}.jpg", 'r') do |f|        
        img = CommercialImage.new
        img.commercial_property_id = p.id
        img.sort_order = headers['object-id']
        img.image = f
        img.save
      end
      
      # Delete the local copy
      File.delete("#{Rails.root}/tmp/#{p.mls_acct}_#{headers['object-id']}.jpg")                
    end    
  end
  
  def self.update_land_images(p)
    self.log "Saving images for land property #{p.mls_acct}..."
    self.client.get_object(:resource => :Property, :type => :Photo, :location => false, :id => p.mls_acct) do |headers, content|
    
      filename = "#{p.mls_acct}_#{headers['object-id']}.jpg"
    
      # Save the file to a temp location
      File.open("#{Rails.root}/tmp/#{p.mls_acct}_#{headers['object-id']}.jpg", 'wb') do |f|
        f.write(content)
      end
      
      # Open it back up and save it to amazon
      File.open("#{Rails.root}/tmp/#{p.mls_acct}_#{headers['object-id']}.jpg", 'r') do |f|        
        img = LandImage.new
        img.land_property_id = p.id
        img.sort_order = headers['object-id']
        img.image = f
        img.save
      end
      
      # Delete the local copy
      File.delete("#{Rails.root}/tmp/#{p.mls_acct}_#{headers['object-id']}.jpg")                
    end    
  end
  
  def self.update_agent_images(agent = nil)
    if (agent.nil?)
      Agent.where(:lo_code => '46').reorder('last_name, first_name').all.each do |a|
        self.update_agent_images(a)
      end
      return
    end
    a = agent
    
    self.log "Saving image for #{a.first_name} #{a.last_name}..."
    begin
      self.client.get_object(:resource => :Agent, :type => :Photo, :location => false, :id => a.la_code) do |headers, content|
        next if headers.nil? || content.nil? || !content
        File.open("#{Rails.root}/tmp/#{a.id}.jpg", 'wb') { |f| f.write(content) }        
        File.open("#{Rails.root}/tmp/#{a.id}.jpg", 'r') do |f|        
          a.image = f
          a.save
        end
        File.delete("#{Rails.root}/tmp/#{a.id}.jpg")                
      end
    rescue RETS::APIError => err
      self.log "No image for #{a.first_name} #{a.last_name}."
    end    
  end
  
  #=============================================================================
  # GPS
  #=============================================================================
  
  def self.update_residential_coords(property = nil)
    if (property.nil?)
      if (ResidentialProperty.where(:latitude => nil).count == 0)
        self.log "All residential properties have GPS coordinates."
        return
      end
      ResidentialProperty.where(:latitude => nil).reorder(:mls_acct).each do |p|
        self.update_residential_coords(p)
      end                         
      self.update_residential_coords
      return
    end
    p = property
      
    coords = self.coords_from_address("#{p.street_num} #{p.street_name}, #{p.city}, #{p.state} #{p.zip}")
    return if coords.nil? || coords == false
    
    p.latitude = coords['lat']
    p.longitude = coords['lng']
    p.save
    self.log "Saved residential property #{p.mls_acct} coords"
  end
  
  def self.update_commercial_coords(property = nil)
    if (property.nil?)
      if (CommercialProperty.where(:latitude => nil).count == 0)
        self.log "All commercial properties have GPS coordinates."
        return
      end
      CommercialProperty.where(:latitude => nil).reorder(:mls_acct).each do |p|
        self.update_commercial_coords(p)
      end
      self.update_commercial_coords
      return
    end
    p = property
          
    coords = self.coords_from_address("#{p.street_num} #{p.street_name}, #{p.city}, #{p.state} #{p.zip}")
    return if coords.nil? || coords == false
    
    p.latitude = coords['lat']
    p.longitude = coords['lng']
    p.save
    self.log "Saved commercial property #{p.mls_acct} coords."
  end
  
  def self.update_land_coords(property = nil)
    if (property.nil?)
      if (LandProperty.where(:latitude => nil).count == 0)
        self.log "All land properties have GPS coordinates."
        return
      end
      LandProperty.where(:latitude => nil).reorder(:mls_acct).each do |p|
        self.update_land_coords(p)
      end
      self.update_land_coords
      return
    end
    p = property
          
    coords = self.coords_from_address("#{p.street_num} #{p.street_name}, #{p.city}, #{p.state} #{p.zip}")
    return if coords.nil? || coords == false
    
    p.latitude = coords['lat']
    p.longitude = coords['lng']
    p.save
    self.log "Saved land property #{p.mls_acct} coords."
  end
  
  def self.coords_from_address(address)   
    begin
      uri = "https://maps.googleapis.com/maps/api/geocode/json?address=#{address}&sensor=false"
      uri.gsub!(" ", "+")
      
      resp = HTTParty.get(uri)
      json = JSON.parse(resp.body)
      return json['results'][0]['geometry']['location']          
    rescue
      self.log "Error: #{uri}"
      sleep(2)
      return false      
    end
  end
  
  #=============================================================================
  # Logging
  #=============================================================================
  
  def self.log(msg)
    puts "[rets_importer] #{msg}"
    Caboose.log("[rets_importer] #{msg}")
  end
  
end
