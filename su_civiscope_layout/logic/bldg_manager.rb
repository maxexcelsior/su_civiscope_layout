# 编码：UTF-8
module CiviscopeLayout
  module Core
    
    def self.do_convert_bldg
      model = Sketchup.active_model
      return if model.selection.empty?
      
      model.start_operation('转换为CIM建筑', true)
      target_layer = self.ensure_layer("CIM-mass")
      
      new_selection = []
      
      model.selection.to_a.each do |t|
        next unless t.respond_to?(:manifold?) && t.manifold?
        inst = t.is_a?(Sketchup::Group) ? t.to_component : t
        inst.layer = target_layer 
        
        inst.set_attribute("dynamic_attributes", "_formatversion", 1.0)
        inst.set_attribute("dynamic_attributes", "floor_height", "3.0")
        inst.set_attribute("dynamic_attributes", "bldg_func", DEFAULT_BLDG_FUNCS[0])
        inst.set_attribute("dynamic_attributes", "bldg_type", "塔楼")
        inst.set_attribute("dynamic_attributes", "bldg_no", "") 
        
        self.attach_observers(inst)
        self.auto_recalculate(inst, true)
        new_selection << inst
      end
      
      model.selection.clear
      model.selection.add(new_selection) unless new_selection.empty?
      self.refresh_stats_ui(model.selection)
      model.commit_operation
    end

    def self.do_apply_bldg(h, f, no, type = nil, th = nil)
      model = Sketchup.active_model
      model.start_operation('修改建筑属性', true)
      model.selection.to_a.each do |inst|
        next unless inst.get_attribute("dynamic_attributes", "bldg_func")
        
        cur_th = inst.get_attribute("dynamic_attributes", "total_height").to_f
        req_th = th.to_f
        
        if req_th > 0 && cur_th > 0 && (cur_th - req_th).abs > 0.01
          inst.make_unique if inst.is_a?(Sketchup::ComponentInstance)
          scale_z = req_th / cur_th
          bnd = inst.bounds
          base_pt = Geom::Point3d.new(bnd.center.x, bnd.center.y, bnd.min.z)
          tr = Geom::Transformation.scaling(base_pt, 1.0, 1.0, scale_z)
          inst.transform!(tr)
        end
        
        inst.set_attribute("dynamic_attributes", "floor_height", h.to_s)
        inst.set_attribute("dynamic_attributes", "bldg_func", f.to_s)
        inst.set_attribute("dynamic_attributes", "bldg_no", no.to_s)
        inst.set_attribute("dynamic_attributes", "bldg_type", type.to_s) if type
        self.auto_recalculate(inst, true, true) 
      end
      self.refresh_stats_ui(model.selection)
      model.commit_operation
    end

    def self.calc_bldg_data(entity, skip_operation = false)
      return unless entity.manifold?
      fh = entity.get_attribute("dynamic_attributes", "floor_height").to_f
      return if fh <= 0

      bounds = entity.bounds
      th_m = ((bounds.max.z - bounds.min.z) * 0.0254).round(2)
      fc = th_m > 0 ? (th_m / fh).floor : 0
      
      vol_m3 = entity.volume * (0.0254 ** 3)
      b_area = th_m > 0 ? (vol_m3 / th_m).round(2) : 0
      t_area = (fc * b_area).round(2)

      bldg_func = entity.get_attribute("dynamic_attributes", "bldg_func")

      # Dynamic floor lines update
      need_update = (entity.get_attribute("dynamic_attributes", "bldg_area") != t_area.to_s) ||
                    (entity.get_attribute("dynamic_attributes", "floor_count") != fc.to_s) ||
                    (entity.get_attribute("dynamic_attributes", "base_area") != b_area.to_s) ||
                    (entity.get_attribute("dynamic_attributes", "total_height") != th_m.to_s)

      if need_update
        model = Sketchup.active_model
        model.start_operation('更新体块数据', true, false, true) unless skip_operation
        
        entity.set_attribute("dynamic_attributes", "total_height", th_m.to_s)
        entity.set_attribute("dynamic_attributes", "floor_count", fc.to_s)
        entity.set_attribute("dynamic_attributes", "base_area", b_area.to_s)
        entity.set_attribute("dynamic_attributes", "bldg_area", t_area.to_s)
        
        # Draw Floor Lines
        self.instance_variable_set(:@skip_recalc, true)
        begin
          self.update_floor_lines(entity, fc, fh)
        ensure
          self.instance_variable_set(:@skip_recalc, false)
        end
        
        model.commit_operation unless skip_operation
      end
    end

    def self.update_floor_lines(entity, floor_count, floor_height_m)
      # Ensure unique for modification
      entity.make_unique rescue nil if entity.respond_to?(:make_unique)

      ents = (entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)) ? entity.definition.entities : nil
      return unless ents

      # Prevent observers from firing during our own modification
      CiviscopeLayout::Core.skip_recalc = true
      
      begin
        # Clear Old
        old_lines = ents.grep(Sketchup::Edge).select { |e| e.get_attribute("civiscope", "is_floor_line") }
        ents.erase_entities(old_lines) if old_lines.any?

      floor_count = floor_count.to_i
      return if floor_count <= 1

      vertex_zs = ents.grep(Sketchup::Edge).flat_map { |e| [e.start.position.z, e.end.position.z] }
      return if vertex_zs.empty?
      
      min_z = vertex_zs.min
      max_z = vertex_zs.max
      
      # Detect base edges (usually the perimeter)
      # Filter for edges that are on the Ground level of the component and part of vertical-only faces
      base_faces = ents.grep(Sketchup::Face).select do |f|
        f.normal.z < -0.99 && (f.bounds.min.z - min_z).abs < 0.001
      end
      
      if base_faces.empty?
        base_edges = ents.grep(Sketchup::Edge).select do |e|
          (e.start.position.z - min_z).abs < 0.001 && (e.end.position.z - min_z).abs < 0.001
        end
      else
        base_edges = base_faces.flat_map(&:edges).uniq
        base_edges.select! do |e|
          (e.start.position.z - min_z).abs < 0.001 && (e.end.position.z - min_z).abs < 0.001
        end
      end

      # Only keep outer edges of the building mass
      base_edges.select! do |e|
        faces = e.faces
        base_face_count = faces.count { |f| f.normal.z.abs > 0.99 && (f.bounds.min.z - min_z).abs < 0.001 }
        base_face_count < 2 
      end

      return if base_edges.empty?

      # Account for local Z scale to keep lines consistent in meters
      local_scale_z = entity.transformation.zscale
      local_fh_inch = (floor_height_m / 0.0254) / local_scale_z
      
      (1..floor_count).each do |i|
        z_offset = i * local_fh_inch
        cur_z = min_z + z_offset
        
        break if (max_z - cur_z) < 0.1 # Stop if too close to top
        
        base_edges.each do |e|
          pt1 = e.start.position
          pt2 = e.end.position
          p1 = Geom::Point3d.new(pt1.x, pt1.y, cur_z)
          p2 = Geom::Point3d.new(pt2.x, pt2.y, cur_z)
          
          line = ents.add_line(p1, p2)
          line.set_attribute("civiscope", "is_floor_line", true) if line
        end
      end
    ensure
      CiviscopeLayout::Core.skip_recalc = false
    end
  end

  end
end
