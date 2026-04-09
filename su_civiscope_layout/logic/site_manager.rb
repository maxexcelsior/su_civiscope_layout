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
        
        # 提取地块外轮廓边线并独立打组（在组件内部）
        definition = inst.definition
        boundary_edges = []
        definition.entities.grep(Sketchup::Face).each do |f|
          f.outer_loop.edges.each do |edge|
            boundary_edges << edge
          end
        end
        
        if boundary_edges.any?
          # 创建边线组
          boundary_group = definition.entities.add_group
          boundary_group.name = "地块边线"
          boundary_group.set_attribute("dynamic_attributes", "site_boundary", "true")
          
          # 复制边线到边线组中（使用顶点位置）
          # 注意：不调用 find_faces，避免自动生成面
          boundary_edges.uniq.each do |edge|
            boundary_group.entities.add_line(edge.start.position, edge.end.position)
          end
        end
        
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
          # 直接使用外环顶点创建面（简化逻辑，避免复杂的loop处理）
          outer_global = face.outer_loop.vertices.map { |v| v.position.transform(tr) }
          outer_user = outer_global.map { |pt| pt.transform(t_user_inv) }
          local_pts = outer_user.map { |pt| Geom::Point3d.new(pt.x - origin_user.x, pt.y - origin_user.y, pt.z - origin_user.z) }
          
          # 创建面
          new_face = group.entities.add_face(local_pts) rescue nil
          
          if new_face && face.loops.length > 1
            # 如果原面有内环（孔洞），创建内环边线形成孔洞
            face.loops[1..-1].each do |inner_loop|
              inner_global = inner_loop.vertices.map { |v| v.position.transform(tr) }
              inner_user = inner_global.map { |pt| pt.transform(t_user_inv) }
              inner_local = inner_user.map { |pt| Geom::Point3d.new(pt.x - origin_user.x, pt.y - origin_user.y, pt.z - origin_user.z) }
              
              # 创建内环边线（会自动在面上形成孔洞）
              inner_local.each_with_index do |pt, i|
                p2 = inner_local[(i+1) % inner_local.length]
                group.entities.add_line(pt, p2)
              end
            end
          end
        rescue => e
          puts e.message
        end
        
        if group.entities.grep(Sketchup::Face).length > 0
          # 先转换为组件，再创建边线组（避免破坏面的几何结构）
          inst = group.to_component
          t_final = t_user * Geom::Transformation.translation(vec_origin_user)
          inst.transform!(t_final)
          
          inst.layer = target_layer
          inst.set_attribute("dynamic_attributes", "site_type", SITE_TYPES[0]) 
          inst.set_attribute("dynamic_attributes", "site_func", DEFAULT_SITE_FUNCS[0])
          inst.set_attribute("dynamic_attributes", "site_no", "") 
          
          # 提取地块外轮廓边线并独立打组（在组件内部）
          definition = inst.definition
          boundary_edges = []
          definition.entities.grep(Sketchup::Face).each do |f|
            f.outer_loop.edges.each do |edge|
              boundary_edges << edge
            end
          end
          
          if boundary_edges.any?
            # 创建边线组
            boundary_group = definition.entities.add_group
            boundary_group.name = "地块边线"
            boundary_group.set_attribute("dynamic_attributes", "site_boundary", "true")
            
            # 复制边线到边线组中（使用顶点位置）
            # 注意：不调用 find_faces，避免自动生成面
            boundary_edges.uniq.each do |edge|
              boundary_group.entities.add_line(edge.start.position, edge.end.position)
            end
          end
          
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
