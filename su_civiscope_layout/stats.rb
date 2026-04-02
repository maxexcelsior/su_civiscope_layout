# 编码：UTF-8
require 'json'

module CiviscopeLayout
  module Core

    @dialog_stats = nil
    @selection_observer = nil
    @entity_observers = {}
    @def_entities_observers = {} 
    @timer_id = nil
    @sel_timer_id = nil
    @current_active_tab = 'tab-bldg'
    @is_tab_switch = false

    class << self
      attr_accessor :timer_id
    end

    def self.ensure_layer(layer_name)
      model = Sketchup.active_model
      model.layers[layer_name] || model.layers.add(layer_name)
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

    def self.show_stats_dialog
      if @dialog_stats && @dialog_stats.visible?
        @dialog_stats.bring_to_front; return
      end
      
      @dialog_stats = UI::HtmlDialog.new({:dialog_title => "📊 统计中心", :width => 320, :height => 550, :style => UI::HtmlDialog::STYLE_DIALOG})
      @dialog_stats.set_file(File.join(__dir__, 'ui', 'ui_stats.html'))
      
      @dialog_stats.add_action_callback("on_tab_changed") do |_, tab_id|
        @current_active_tab = tab_id
        @is_tab_switch = true
        self.refresh_stats_ui(Sketchup.active_model.selection)
        @is_tab_switch = false
      end

      @dialog_stats.add_action_callback("convert_bldg") { self.do_convert_bldg }
      @dialog_stats.add_action_callback("apply_bldg") { |_, h, f, no| self.do_apply_bldg(h, f, no) }
      @dialog_stats.add_action_callback("convert_site") { self.do_convert_site }
      @dialog_stats.add_action_callback("apply_site") { |_, t, f, no| self.do_apply_site(t, f, no) }
      @dialog_stats.add_action_callback("start_picker") { |_, mode| Sketchup.active_model.select_tool(FunctionPickerTool.new(mode)) }
      @dialog_stats.add_action_callback("export_data") { |_, mode| UI.messagebox((mode == 'bldg' ? "建筑" : "用地") + "导出表单功能开发中...") }
      @dialog_stats.add_action_callback("faces_to_sites") { self.do_faces_to_sites }
      @dialog_stats.add_action_callback("ready") { self.refresh_stats_ui(Sketchup.active_model.selection) }
      @dialog_stats.set_on_closed { @dialog_stats = nil }
      @dialog_stats.show
      
      unless @selection_observer
        @selection_observer = SelectionWatcher.new
        Sketchup.active_model.selection.add_observer(@selection_observer)
      end
    end

    def self.get_short_id(t); t.persistent_id != 0 ? t.persistent_id.to_s : t.guid.split('-').first; end

    def self.get_active_targets(sel)
      model = Sketchup.active_model
      if model.active_path && !model.active_path.empty?
        model.active_path.reverse.each do |inst|
          if inst.get_attribute("dynamic_attributes", "bldg_func") || inst.get_attribute("dynamic_attributes", "site_func")
            return [inst] 
          end
        end
      end
      sel.grep(Sketchup::Group) + sel.grep(Sketchup::ComponentInstance)
    end

    def self.refresh_stats_ui(sel)
      return unless @dialog_stats
      
      targets = self.get_active_targets(sel)
      
      if targets.empty?
        @dialog_stats.execute_script("showEmptyState()")
        return
      end

      bldg_targets = targets.select { |t| t.get_attribute("dynamic_attributes", "bldg_func") }
      site_targets = targets.select { |t| t.get_attribute("dynamic_attributes", "site_func") }
      normal_targets = targets - bldg_targets - site_targets

      if bldg_targets.any?
        render_targets('bldg', bldg_targets)
      elsif site_targets.any?
        render_targets('site', site_targets)
      else
        if @is_tab_switch
          active_type = @current_active_tab == 'tab-site' ? 'site' : 'bldg'
          @dialog_stats.execute_script("refreshUI('#{active_type}', 'normal', [], [], {})")
        else
          first_normal = normal_targets.first
          if first_normal.respond_to?(:manifold?) && first_normal.manifold?
            @dialog_stats.execute_script("refreshUI('bldg', 'normal', [], [], {})")
          else
            @dialog_stats.execute_script("refreshUI('site', 'normal', [], [], {})")
          end
        end
      end
    end

    def self.render_targets(type, valid_targets)
      all_funcs = self.get_all_funcs(type)
      
      if valid_targets.length == 1
        t = valid_targets.first
        self.attach_observers(t)
        
        data = { id: self.get_short_id(t), no: t.get_attribute("dynamic_attributes", "#{type}_no") || "" }
        if type == 'bldg'
          data.merge!({
            h: t.get_attribute("dynamic_attributes", "floor_height"),
            f: t.get_attribute("dynamic_attributes", "bldg_func"),
            th: t.get_attribute("dynamic_attributes", "total_height"),
            fc: t.get_attribute("dynamic_attributes", "floor_count"),
            ba: t.get_attribute("dynamic_attributes", "base_area"),
            area: t.get_attribute("dynamic_attributes", "bldg_area")
          })
          @dialog_stats.execute_script("refreshUI('bldg', 'bim', [], #{all_funcs.to_json}, #{data.to_json})")
        else
          bldgs_in_site = self.find_buildings_on_site(t)
          data.merge!({
            t: t.get_attribute("dynamic_attributes", "site_type"),
            f: t.get_attribute("dynamic_attributes", "site_func"),
            area: t.get_attribute("dynamic_attributes", "site_area"),
            bldgs: bldgs_in_site
          })
          @dialog_stats.execute_script("refreshUI('site', 'bim', #{SITE_TYPES.to_json}, #{all_funcs.to_json}, #{data.to_json})")
        end
        
      else
        list_data = []
        total_area = 0.0
        valid_targets.each do |t|
          self.attach_observers(t)
          area_val = t.get_attribute("dynamic_attributes", "#{type}_area").to_f
          total_area += area_val
          list_data << { 
            id: self.get_short_id(t), 
            no: t.get_attribute("dynamic_attributes", "#{type}_no") || "",
            f: t.get_attribute("dynamic_attributes", "#{type}_func"), 
            t: t.get_attribute("dynamic_attributes", "site_type") || "", 
            area: area_val.round(2) 
          }
        end
        @dialog_stats.execute_script("refreshUI('#{type}', 'multi', [], [], { list: #{list_data.to_json}, totalArea: #{total_area} })")
      end
    end

    def self.find_buildings_on_site(site)
      model = Sketchup.active_model
      bldgs = []
      
      all_bldgs = []
      model.entities.each do |e|
        next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        all_bldgs << e if e.get_attribute("dynamic_attributes", "bldg_func")
      end
      
      all_bldgs.each do |bldg|
        next unless site.bounds.intersect(bldg.bounds).valid?
        
        center = bldg.bounds.center
        bottom_center = Geom::Point3d.new(center.x, center.y, bldg.bounds.min.z)
        
        if self.point_in_site_vertical?(bottom_center, site)
          area = bldg.get_attribute("dynamic_attributes", "bldg_area").to_f || 0.0
          bldgs << { 
            id: self.get_short_id(bldg), 
            no: bldg.get_attribute("dynamic_attributes", "bldg_no") || "",
            f: bldg.get_attribute("dynamic_attributes", "bldg_func") || "",
            area: area.round(2)
          }
        end
      end
      bldgs
    end

    def self.point_in_site_vertical?(global_pt, site)
      tr_inv = site.transformation.inverse
      local_pt = global_pt.transform(tr_inv)
      
      global_pt2 = global_pt + Geom::Vector3d.new(0, 0, -1)
      local_pt2 = global_pt2.transform(tr_inv)
      local_vec = local_pt.vector_to(local_pt2)
      return false unless local_vec.valid?
      
      line = [local_pt, local_vec]
      
      definition = site.is_a?(Sketchup::Group) ? site.definition : site.definition
      definition.entities.grep(Sketchup::Face).each do |face|
        intersect_pt = Geom.intersect_line_plane(line, face.plane)
        next unless intersect_pt
        
        res = face.classify_point(intersect_pt)
        if [Sketchup::Face::PointInside, Sketchup::Face::PointOnFace, Sketchup::Face::PointOnEdge, Sketchup::Face::PointOnVertex].include?(res)
          return true
        end
      end
      false
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

    def self.do_apply_bldg(h, f, no)
      model = Sketchup.active_model
      model.start_operation('转换为CIM建筑', true)
      model.selection.to_a.each do |inst|
        next unless inst.get_attribute("dynamic_attributes", "bldg_func")
        inst.set_attribute("dynamic_attributes", "floor_height", h.to_s)
        inst.set_attribute("dynamic_attributes", "bldg_func", f.to_s)
        inst.set_attribute("dynamic_attributes", "bldg_no", no.to_s)
        self.auto_recalculate(inst, true, true) 
      end
      self.refresh_stats_ui(model.selection)
      model.commit_operation
    end

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

    def self.do_apply_site(t, f, no)
      model = Sketchup.active_model
      model.start_operation('修改建筑功能', true)
      model.selection.to_a.each do |inst|
        next unless inst.get_attribute("dynamic_attributes", "site_func")
        inst.set_attribute("dynamic_attributes", "site_type", t.to_s)
        inst.set_attribute("dynamic_attributes", "site_func", f.to_s)
        inst.set_attribute("dynamic_attributes", "site_no", no.to_s)
        self.auto_recalculate(inst, true, true) 
      end
      self.refresh_stats_ui(model.selection)
      model.commit_operation
    end

    def self.auto_recalculate(entity, skip_ui_refresh = false, skip_operation = false)
      return unless entity.valid?
      
      if entity.get_attribute("dynamic_attributes", "bldg_func")
        bldg_func = entity.get_attribute("dynamic_attributes", "bldg_func")
        self.apply_material(entity, bldg_func)
        self.calc_bldg_data(entity, skip_operation)
      elsif entity.get_attribute("dynamic_attributes", "site_func")
        site_func = entity.get_attribute("dynamic_attributes", "site_func")
        site_type = entity.get_attribute("dynamic_attributes", "site_type") || site_func
        self.apply_material(entity, site_func, site_type)
        self.calc_site_data(entity, skip_operation)
      end
      
      self.refresh_stats_ui(Sketchup.active_model.selection) unless skip_ui_refresh
    end

    def self.calc_bldg_data(entity, skip_operation = false)
      return unless entity.manifold?
      fh = entity.get_attribute("dynamic_attributes", "floor_height").to_f
      return if fh <= 0

      bounds = entity.bounds
      th_m = ((bounds.max.z - bounds.min.z) * 0.0254).round(2)
      fc = th_m > 0 ? (th_m / fh).floor : 0
      
      vol_m3 = entity.volume * (0.0254 ** 3)
      t_area = (vol_m3 / fh).round(2)
      b_area = th_m > 0 ? (vol_m3 / th_m).round(2) : 0

      bldg_func = entity.get_attribute("dynamic_attributes", "bldg_func")

      need_update = (entity.get_attribute("dynamic_attributes", "bldg_area") != t_area.to_s) ||
                    (entity.get_attribute("dynamic_attributes", "floor_count") != fc.to_s) ||
                    (entity.get_attribute("dynamic_attributes", "base_area") != b_area.to_s) ||
                    (entity.get_attribute("dynamic_attributes", "total_height") != th_m.to_s)

      if need_update
        model = Sketchup.active_model
        model.start_operation('更新体块数据', true, false, true) unless skip_operation
        
        entity.set_attribute("dynamic_attributes", "bldg_area", t_area.to_s)
        entity.set_attribute("dynamic_attributes", "floor_count", fc.to_s)
        entity.set_attribute("dynamic_attributes", "base_area", b_area.to_s)
        entity.set_attribute("dynamic_attributes", "total_height", th_m.to_s)
        
        self.class_variable_set(:@@skip_observer, true)
        begin
          self.update_floor_lines(entity, fc, fh)
        ensure
          self.class_variable_set(:@@skip_observer, false)
        end
        
        model.commit_operation unless skip_operation
      end
    end

    def self.update_floor_lines(entity, floor_count, floor_height_m)
      ents = (entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)) ? entity.definition.entities : nil
      return unless ents

      old_lines = ents.grep(Sketchup::Edge).select { |e| e.get_attribute("civiscope", "is_floor_line") }
      ents.erase_entities(old_lines) if old_lines.any?

      floor_count = floor_count.to_i
      return if floor_count <= 1

      vertex_zs = ents.grep(Sketchup::Edge).flat_map { |e| [e.start.position.z, e.end.position.z] }
      return if vertex_zs.empty?
      
      min_z = vertex_zs.min
      max_z = vertex_zs.max
      
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

      base_edges.select! do |e|
        faces = e.faces
        base_face_count = faces.count { |f| f.normal.z.abs > 0.99 && (f.bounds.min.z - min_z).abs < 0.001 }
        base_face_count < 2 
      end

      return if base_edges.empty?

      local_scale_z = entity.transformation.zscale
      local_fh_inch = (floor_height_m / 0.0254) / local_scale_z
      
      (1...floor_count).each do |i|
        z_offset = i * local_fh_inch
        cur_z = min_z + z_offset
        
        break if (max_z - cur_z) < 0.1
        
        base_edges.each do |e|
          pt1 = e.start.position
          pt2 = e.end.position
          p1 = Geom::Point3d.new(pt1.x, pt1.y, cur_z)
          p2 = Geom::Point3d.new(pt2.x, pt2.y, cur_z)
          
          line = ents.add_line(p1, p2)
          line.set_attribute("civiscope", "is_floor_line", true) if line
        end
      end
    end

    def self.calc_site_data(entity, skip_operation = false)
      total_face_area_sq_inch = 0.0
      entity.definition.entities.grep(Sketchup::Face).each do |face|
        total_face_area_sq_inch += face.area
      end
      
      tr = entity.transformation
      scale_factor = tr.xscale * tr.yscale
      site_area_m2 = (total_face_area_sq_inch * scale_factor * (0.0254 ** 2)).round(2)
      
      site_type = entity.get_attribute("dynamic_attributes", "site_type")
      site_func = entity.get_attribute("dynamic_attributes", "site_func") || site_type

      if entity.get_attribute("dynamic_attributes", "site_area") != site_area_m2.to_s
        model = Sketchup.active_model
        model.start_operation('更新体块数据', true, false, true) unless skip_operation
        entity.set_attribute("dynamic_attributes", "site_area", site_area_m2.to_s)
        model.commit_operation unless skip_operation
      end
    end

    class MassingEntityObserver < Sketchup::EntityObserver
      def onChangeEntity(e)
        return if CiviscopeLayout::Core.class_variable_defined?(:@@skip_observer) && CiviscopeLayout::Core.class_variable_get(:@@skip_observer)
        CiviscopeLayout::Core.schedule_update(e)
      end
      def onEraseEntity(e)
        CiviscopeLayout::Core.refresh_stats_ui(Sketchup.active_model.selection)
      end
    end

    class BimEntitiesObserver < Sketchup::EntitiesObserver
      def initialize(d); @definition = d; end
      def onElementAdded(es, e); trigger_update; end
      def onElementModified(es, e); trigger_update; end
      def onElementRemoved(es, e); trigger_update; end
      def trigger_update
        @definition.instances.each { |inst| CiviscopeLayout::Core.schedule_update(inst) }
      end
    end

    class SelectionWatcher < Sketchup::SelectionObserver
      def onSelectionBulkChange(sel)
        UI.stop_timer(@sel_timer_id) if @sel_timer_id
        @sel_timer_id = UI.start_timer(0.1, false) do
          CiviscopeLayout::Core.refresh_stats_ui(Sketchup.active_model.selection)
        end
      end
      
      def onSelectionCleared(sel)
        CiviscopeLayout::Core.refresh_stats_ui(sel)
      end
    end

    def self.schedule_update(entity)
      UI.stop_timer(@timer_id) if @timer_id
      @timer_id = UI.start_timer(0.3, false) do
        self.auto_recalculate(entity)
      end
    end

    def self.attach_observers(instance)
      return unless instance.valid?
      unless @entity_observers[instance.guid]
        obs1 = MassingEntityObserver.new
        instance.add_observer(obs1)
        @entity_observers[instance.guid] = obs1
      end
      definition = instance.definition
      unless @def_entities_observers[definition.guid]
        obs2 = BimEntitiesObserver.new(definition)
        definition.entities.add_observer(obs2)
        @def_entities_observers[definition.guid] = obs2
      end
    end

    class FunctionPickerTool
      def initialize(mode = 'bldg')
        @mode = mode 
        @state = :pick
        @picked_func = nil
        @picked_type = nil 
        
        icon_dir = File.join(__dir__, 'icon')
        pick_path = File.join(icon_dir, 'picker.png')
        paint_path = File.join(icon_dir, 'paint.png')
        
        @cursor_pick = File.exist?(pick_path) ? UI.create_cursor(pick_path, 0, 0) : 632 
        @cursor_paint = File.exist?(paint_path) ? UI.create_cursor(paint_path, 0, 0) : 636
      end

      def onSetCursor
        cursor_id = @state == :pick ? @cursor_pick : @cursor_paint
        UI.set_cursor(cursor_id) if cursor_id != 0
      end

      def activate
        update_ui
      end

      def resume(view)
        update_ui
      end

      def update_ui
        val = if @state == :pick
                "[吸取]"
              else
                @mode == 'bldg' ? "[刷入]:#{@picked_func}" : "[刷入]:#{@picked_type}-#{@picked_func}"
              end
        mode_text = @mode == 'bldg' ? "建筑" : "用地"
        Sketchup.status_text = "#{mode_text}属性刷 | #{val} | 按ESC退出"
      end

      def onMouseMove(flags, x, y, view)
        msg = if @state == :pick
                @mode == 'bldg' ? "点击吸取建筑功能" : "点击吸取地块属性"
              else
                @mode == 'bldg' ? "赋予: #{@picked_func}\n(ESC取消)" : "赋予: #{@picked_type}-#{@picked_func}\n(ESC取消)"
              end
        view.tooltip = msg
        view.invalidate
      end

      def onLButtonDown(flags, x, y, view)
        ph = view.pick_helper
        ph.do_pick(x, y)
        target = ph.best_picked
        
        unless target && (target.is_a?(Sketchup::Group) || target.is_a?(Sketchup::ComponentInstance))
          if ph.count > 0
            path = ph.path_at(0)
            target = path.reverse.find { |e| e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance) }
          end
        end
        return unless target

        model = Sketchup.active_model

        if @state == :pick
          if @mode == 'bldg'
            func = target.get_attribute("dynamic_attributes", "bldg_func")
            if func
              @picked_func = func
              @state = :paint
              update_ui
              view.invalidate
            else
              UI.beep
            end
          elsif @mode == 'site'
            func = target.get_attribute("dynamic_attributes", "site_func")
            type = target.get_attribute("dynamic_attributes", "site_type")
            if func && type
              @picked_func = func
              @picked_type = type
              @state = :paint
              update_ui
              view.invalidate
            else
              UI.beep
            end
          end

        elsif @state == :paint
          if @mode == 'bldg'
            if target.get_attribute("dynamic_attributes", "bldg_func")
              model.start_operation('格式刷:赋予建筑功能', true)
              target.set_attribute("dynamic_attributes", "bldg_func", @picked_func)
              CiviscopeLayout::Core.auto_recalculate(target, true, true)
              model.commit_operation
              
              CiviscopeLayout::Core.refresh_stats_ui(model.selection) if model.selection.contains?(target)
            else
              UI.beep
            end
          elsif @mode == 'site'
            if target.get_attribute("dynamic_attributes", "site_func")
              model.start_operation('格式刷:赋予用地功能', true)
              target.set_attribute("dynamic_attributes", "site_func", @picked_func)
              target.set_attribute("dynamic_attributes", "site_type", @picked_type)
              CiviscopeLayout::Core.auto_recalculate(target, true, true)
              model.commit_operation
              
              CiviscopeLayout::Core.refresh_stats_ui(model.selection) if model.selection.contains?(target)
            else
              UI.beep
            end
          end
        end
      end

      def onCancel(reason, view)
        Sketchup.active_model.select_tool(nil)
        Sketchup.status_text = ""
        view.tooltip = ""
        view.invalidate
      end
    end

  end
end
