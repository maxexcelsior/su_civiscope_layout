# 编码：UTF-8
module CiviscopeLayout
  module Core
    
    def self.ensure_layer(layer_name)
      model = Sketchup.active_model
      model.layers[layer_name] || model.layers.add(layer_name)
    end

    def self.get_short_id(t)
      return "0" unless t
      t.persistent_id != 0 ? t.persistent_id.to_s : t.guid.split('-').first
    end

    def self.apply_material(entity, func_name, type_name = nil)
      return unless func_name && !func_name.empty?
      mats = Sketchup.active_model.materials
      
      custom_colors = (CiviscopeLayout::Core.get_custom_colors rescue {}) || {}
      
      hex = custom_colors[func_name]
      color_rgb = COLOR_MAP[func_name]
      
      if (hex.nil? || hex.empty?) && color_rgb.nil? && type_name && !type_name.empty?
        hex = custom_colors[type_name]
        color_rgb = COLOR_MAP[type_name]
        mat_key = type_name
      else
        mat_key = func_name
      end
      
      mat_name = "Civiscope_#{mat_key}"
      mat = mats[mat_name] || mats.add(mat_name)
      
      if hex && !hex.empty?
        mat.color = hex
      else
        color_rgb ||= [230, 230, 230] 
        mat.color = Sketchup::Color.new(color_rgb[0], color_rgb[1], color_rgb[2])
      end
      
      if entity.material.nil? || entity.material.name != mat.name
        entity.material = mat
      end
    end

  end
end
