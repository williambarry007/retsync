class CommercialImage < ActiveRecord::Base
  belongs_to :commercial_property
  attr_accessible :id, :commercial_property_id, :name, :sort_order  
  has_attached_file :image, 
    :path => 'commercial/:commercial_property_id_:sort_order_:style.:extension', 
    :styles => {
      :tiny  => '160x120>',
      :thumb => '400x300>',
      :large => '640x480>'
    }
    
end
                                     