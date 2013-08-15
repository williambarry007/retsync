class Property < ActiveRecord::Base
  self.table_name = "properties"
  has_many :property_images

  def agent
    return Agent.where(:la_code => self.la_code).first
  end

  def office
    return Office.where(:lo_code => self.lo_code).first
  end

  def self.geolocatable
    all(conditions: "latitude IS NOT NULL AND longitude IS NOT NULL")
  end

  def parse(data)
    self.column_names.each do |col|
      next if data[col.upcase].nil?
      self[col.to_sym] = data[col.upcase]
    end
	end
end
