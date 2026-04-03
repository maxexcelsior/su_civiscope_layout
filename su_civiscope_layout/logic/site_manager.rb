# 编码：UTF-8
module CiviscopeLayout
  module Core
    
    def self.do_convert_site
      model = Sketchup.active_model
      model.start_operation('转换为CIM建筑', true)
      target_layer = self.ensure_layer("CIM-plot")

      new_selection = []
      model.selection.to_a.each do |t|
        next unless t.is_a?(Sketchup::Group) || t.is_a?(Sketchup::ComponentInstance)
        inst = t.is_a?(Sketchup::Group) ? t.to_component : t
        inst.layer = target_layer 

        inst.set_attribute("dynamic_attributes", "site_type", SITE_TYPES[0]) 
        inst.set_attribute("dynamic_attributes", "site_func", DEFAULT_SITE_FUNCS[0])
        inst.set_attribute("dynamic_attributes", "site_no", "") 
        
        self.attach_observers(inst)
        self.auto_recalculate(inst, true, true)
        new_selection << inst
      end
      
      model.selection.clear
      model.selection.add(new_selection) unless new_selection.empty?
      self.refresh_stats_ui(model.selection)
      model.commit_operation
    end

    def self.do_apply_site(t, f, no, hl)
      model = Sketchup.active_model
      model.start_operation('修改地块属性', true)
      model.selection.to_a.each do |inst|
        next unless inst.get_attribute("dynamic_attributes", "site_func")
        inst.set_attribute("dynamic_attributes", "site_type", t.to_s)
        inst.set_attribute("dynamic_attributes", "site_func", f.to_s)
        inst.set_attribute("dynamic_attributes", "site_no", no.to_s)
        inst.set_attribute("dynamic_attributes", "height_limit", hl.to_s)
        self.auto_recalculate(inst, true, true) 
      end
      self.refresh_stats_ui(model.selection)
      UI.start_timer(0, false) { Sketchup.active_model.active_view.refresh }
      model.commit_operation
    end

    def self.do_faces_to_sites
      model = Sketchup.active_model
      face_data = []
      
      faces = model.selection.grep(Sketchup::Face)
      if faces.empty?
        model.selection.grep(Sketchup::Group).each do |g|
          tr = g.transformation
          g.entities.grep(Sketchup::Face).each { |f| face_data << { face: f, tr: tr } }
        end
        model.selection.grep(Sketchup::ComponentInstance).each do |c|
          tr = c.transformation
          c.definition.entities.grep(Sketchup::Face).each { |f| face_data << { face: f, tr: tr } }
        end
      else
        faces.each { |f| face_data << { face: f, tr: IDENTITY } }
      end
      
      if face_data.empty?
        UI.messagebox("请先选择面！")
        return
      end

      model.start_operation('面转地块', true)
      target_layer = self.ensure_layer("CIM-plot")
      new_selection = []
      
      t_user = model.axes.transformation
      t_user_inv = t_user.inverse
      
      face_data.each do |data|
        face = data[:face]
        tr = data[:tr]
        next unless face.valid?
        group = model.active_entities.add_group
        
        global_vertices = face.vertices.map { |v| v.position.transform(tr) }
        user_vertices = global_vertices.map { |pt| pt.transform(t_user_inv) }
        
        min_x = user_vertices.map(&:x).min
        min_y = user_vertices.map(&:y).min
        min_z = user_vertices.map(&:z).min
        origin_user = Geom::Point3d.new(min_x, min_y, min_z)
        vec_origin_user = Geom::Vector3d.new(origin_user.x, origin_user.y, origin_user.z)
        
        begin
          added_edges = []
          face.loops.each do |loop|
            pts_global = loop.vertices.map { |v| v.position.transform(tr) }
            pts_user = pts_global.map { |pt| pt.transform(t_user_inv) }
            local_pts = pts_user.map { |pt| Geom::Point3d.new(pt.x - origin_user.x, pt.y - origin_user.y, pt.z - origin_user.z) }
            local_pts.each_with_index do |pt, i|
              p2 = local_pts[(i+1) % local_pts.length]
              added_edges << group.entities.add_line(pt, p2)
            end
          end
          added_edges.compact!
          added_edges.first.find_faces if added_edges.first
        rescue => e
          puts e.message
        end
        
        if group.entities.grep(Sketchup::Face).empty?
          outer_global = face.outer_loop.vertices.map { |v| v.position.transform(tr) }
          outer_user = outer_global.map { |pt| pt.transform(t_user_inv) }
          local_pts = outer_user.map { |pt| Geom::Point3d.new(pt.x - origin_user.x, pt.y - origin_user.y, pt.z - origin_user.z) }
          group.entities.add_face(local_pts) rescue nil
        end
        
        if group.entities.grep(Sketchup::Face).length > 0
          inst = group.to_component
          t_final = t_user * Geom::Transformation.translation(vec_origin_user)
          inst.transform!(t_final)
          
          inst.layer = target_layer
          inst.set_attribute("dynamic_attributes", "site_type", SITE_TYPES[0]) 
          inst.set_attribute("dynamic_attributes", "site_func", DEFAULT_SITE_FUNCS[0])
          inst.set_attribute("dynamic_attributes", "site_no", "") 
          
          self.attach_observers(inst)
          self.auto_recalculate(inst, true, true)
          new_selection << inst
          
          face.erase! if face.valid?
        else
          group.erase!
        end
      end
      
      model.selection.clear
      model.selection.add(new_selection) unless new_selection.empty?
      self.refresh_stats_ui(model.selection)
      model.commit_operation
    end

    def self.do_activate_greenery_tool
      model = Sketchup.active_model
      mat_name = "Civiscope_内部绿地"
      mat = model.materials[mat_name]
      
      unless mat
        mat = model.materials.add(mat_name)
        mat.color = "#bee599"
      end
      
      model.materials.current = mat
      Sketchup.send_action("selectPaintTool:")
    end

  end
end
