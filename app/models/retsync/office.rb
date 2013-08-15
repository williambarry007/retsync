class Office < ActiveRecord::Base
  self.table_name = "rets_offices"
  attr_accessible :id, :name, :lo_code

end
