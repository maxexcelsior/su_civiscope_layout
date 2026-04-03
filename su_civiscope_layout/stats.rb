# 编码：UTF-8
require 'json'

module CiviscopeLayout
  module Core

    @dialog_stats = nil
    @selection_observer = nil
    @model_observer = nil
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
      
      w, h = self.get_stats_size
      @dialog_stats = UI::HtmlDialog.new({:dialog_title => "📊 统计中心", :width => w, :height => h, :style => UI::HtmlDialog::STYLE_DIALOG})
      @dialog_stats.set_file(File.join(__dir__, 'ui', 'ui_stats.html'))
      
      # Ensure overlay is registered
      @overlay ||= CiviscopeHeightCheckOverlay.new
      begin
        Sketchup.active_model.overlays.add(@overlay)
      rescue => e
        # Might already be added or not supported
      end
      
      
      @dialog_stats.add_action_callback("on_tab_changed") do |_, tab_id|
        @current_active_tab = tab_id
        @is_tab_switch = true
        self.refresh_stats_ui(Sketchup.active_model.selection)
        @is_tab_switch = false
      end

      @dialog_stats.add_action_callback("convert_bldg") { self.do_convert_bldg }
      @dialog_stats.add_action_callback("apply_bldg") { |_, h, f, no, type, th| self.do_apply_bldg(h, f, no, type, th) }
      @dialog_stats.add_action_callback("convert_site") { self.do_convert_site }
      @dialog_stats.add_action_callback("apply_site") { |_, t, f, no, hl| self.do_apply_site(t, f, no, hl) }
      @dialog_stats.add_action_callback("toggle_height_check") { |_, id| self.do_toggle_height_check(id) }
      @dialog_stats.add_action_callback("set_all_height_checks") { |_, status| self.do_set_all_height_checks(status) }
      @dialog_stats.add_action_callback("start_picker") { |_, mode| Sketchup.active_model.select_tool(FunctionPickerTool.new(mode)) }
      @dialog_stats.add_action_callback("export_data") { |_, mode| UI.messagebox((mode == 'bldg' ? "建筑" : "用地") + "导出表单功能开发中...") }
      @dialog_stats.add_action_callback("faces_to_sites") { self.do_faces_to_sites }
      @dialog_stats.add_action_callback("ready") { self.refresh_stats_ui(Sketchup.active_model.selection) }
      @dialog_stats.add_action_callback("on_resized") { |_, w, h| self.save_stats_size(w.to_i, h.to_i) }
      @dialog_stats.set_on_closed { @dialog_stats = nil }
      @dialog_stats.show
      
      # Idempotent Observer Registration
      model = Sketchup.active_model
      
      # Remove old ones if they exist (prevents stacking on reloads)
      if @selection_observer
        begin; model.selection.remove_observer(@selection_observer); rescue; end
      end
      if @model_observer
        begin; model.remove_observer(@model_observer); rescue; end
      end

      @selection_observer = SelectionWatcher.new
      model.selection.add_observer(@selection_observer)
      
      @model_observer = ModelWatcher.new
      model.add_observer(@model_observer)
    end

    def self.get_short_id(t); t.persistent_id != 0 ? t.persistent_id.to_s : t.guid.split('-').first; end

    def self.get_active_targets(sel)
      model = Sketchup.active_model
      @nested_bp_warning = false # Reset flag
      
      # Handle Active Path (Editing inside a Group)
      if model.active_path && !model.active_path.empty?
        model.active_path.reverse.each do |inst|
          if inst.get_attribute("dynamic_attributes", "bldg_func") || inst.get_attribute("dynamic_attributes", "site_func")
            return [inst] 
          end
        end
      end
      
      processed_targets = []
      sel.each do |ent|
        if ent.is_a?(Sketchup::Face)
          processed_targets << ent
          next
        end
        next unless ent.is_a?(Sketchup::Group) || ent.is_a?(Sketchup::ComponentInstance)
        
        
        is_bldg = ent.get_attribute("dynamic_attributes", "bldg_func")
        is_site = ent.get_attribute("dynamic_attributes", "site_func")
        
        if is_bldg || is_site
          processed_targets << ent
        else
          # Check if this "normal" group is a BP Group (Container)
          inner_cim = self.collect_cim_entities(ent)
          if inner_cim.any?
            # Check for nesting: if inner CIMs are grouped themselves
            @nested_bp_warning = true if self.detect_nesting?(ent)
            
            # Treat the inner Site as the target if it exists, otherwise buildings
            site = inner_cim.find { |e| e.get_attribute("dynamic_attributes", "site_func") }
            if site
              processed_targets << site
            else
              processed_targets += inner_cim.select { |e| e.get_attribute("dynamic_attributes", "bldg_func") }
            end
          else
            processed_targets << ent # Still treat as normal group for conversion prompt
          end
        end
      end
      
      processed_targets.uniq
    end

    def self.collect_cim_entities(container)
      results = []
      definition = container.is_a?(Sketchup::Group) ? container.definition : container.definition
      definition.entities.each do |e|
        next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        if e.get_attribute("dynamic_attributes", "bldg_func") || e.get_attribute("dynamic_attributes", "site_func")
          results << e
        end
      end
      results
    end

    def self.detect_nesting?(container)
      definition = container.is_a?(Sketchup::Group) ? container.definition : container.definition
      definition.entities.each do |e|
        next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        # If a child contains another CIM entity internally, it's nested
        inner = self.collect_cim_entities(e)
        return true if inner.any?
      end
      false
    end

    def self.refresh_stats_ui(sel)
      return unless @dialog_stats
      begin
        targets = self.get_active_targets(sel)
        
        if targets.empty?
          @dialog_stats.execute_script("showEmptyState()")
          return
        end

        # Warning Banner logic
        if @nested_bp_warning
          @dialog_stats.execute_script("showBanner('warning', '检测到嵌套的 BP 组。建议一个 BP 组下仅保留一个地块和若干建筑以确保计算准确性。')")
        else
          @dialog_stats.execute_script("hideBanner()")
        end

        bldg_targets = targets.select { |t| t.get_attribute("dynamic_attributes", "bldg_func") }
        site_targets = targets.select { |t| t.get_attribute("dynamic_attributes", "site_func") }
        normal_targets = targets - bldg_targets - site_targets

        if bldg_targets.any?
          render_targets('bldg', bldg_targets, sel)
        elsif site_targets.any?
          render_targets('site', site_targets, sel)
        else
          if @is_tab_switch
            active_type = @current_active_tab == 'tab-site' ? 'site' : 'bldg'
            @dialog_stats.execute_script("refreshUI('#{active_type}', 'normal', [], [], {})")
          else
            first_normal = normal_targets.first
            if first_normal && first_normal.respond_to?(:manifold?) && first_normal.manifold?
              @dialog_stats.execute_script("refreshUI('bldg', 'normal', [], [], {})")
            else
              @dialog_stats.execute_script("refreshUI('site', 'normal', [], [], {})")
            end
          end
        end
      rescue => e
        puts "[Civiscope Error] UI Refresh Failed: #{e.message}\n#{e.backtrace[0..3].join("\n")}"
      end
    end

    def self.render_targets(type, valid_targets, sel)
      all_funcs = self.get_all_funcs(type)
      
      if valid_targets.length == 1
        t = valid_targets.first
        self.attach_observers(t)
        
        sel_array = sel.to_a
        mode = sel_array.include?(t) ? 'bim' : 'bp_group'
        
        data = { id: self.get_short_id(t), no: t.get_attribute("dynamic_attributes", "#{type}_no") || "" }

        if type == 'bldg'
          data.merge!({
            h: t.get_attribute("dynamic_attributes", "floor_height"),
            f: t.get_attribute("dynamic_attributes", "bldg_func"),
            th: t.get_attribute("dynamic_attributes", "total_height"),
            fc: t.get_attribute("dynamic_attributes", "floor_count"),
            ba: t.get_attribute("dynamic_attributes", "base_area"),
            area: t.get_attribute("dynamic_attributes", "bldg_area"),
            type: t.get_attribute("dynamic_attributes", "bldg_type") || "塔楼"
          })
          @dialog_stats.execute_script("refreshUI('bldg', '#{mode}', [], #{all_funcs.to_json}, #{data.to_json})")
        else
          bldgs_in_site = self.find_buildings_on_site(t)
          # Pre-calculate stats for BP Group mode
          t_gfa = bldgs_in_site.reduce(0) { |sum, b| sum + (b[:area] || 0) }
          t_base = bldgs_in_site.reduce(0) { |sum, b| sum + (b[:base_area] || 0) }
          site_area = t.get_attribute("dynamic_attributes", "site_area").to_f
          site_area = site_area > 0 ? site_area : 0.001
          
          has_global_hl = @overlay && !@overlay.sites_data.empty?
          data.merge!({
            t: t.get_attribute("dynamic_attributes", "site_type"),
            f: t.get_attribute("dynamic_attributes", "site_func"),
            area: t.get_attribute("dynamic_attributes", "site_area"),
            hl: t.get_attribute("dynamic_attributes", "height_limit") || "0",
            bldgs: bldgs_in_site,
            gfa: t_gfa.round(2),
            far: (t_gfa / site_area).round(2),
            density: ((t_base / site_area) * 100).round(1),
            is_checking: (@overlay && @overlay.sites_data.key?(self.get_short_id(t))),
            global_hl_on: has_global_hl
          })
          @dialog_stats.execute_script("refreshUI('site', '#{mode}', #{SITE_TYPES.to_json}, #{all_funcs.to_json}, #{data.to_json})")
        end
        
      else
        list_data = []
        total_area = 0.0
        valid_targets.each do |t|
          self.attach_observers(t)
          area_val = t.get_attribute("dynamic_attributes", "#{type}_area").to_f
          total_area += area_val
          
          item = { 
            id: self.get_short_id(t), 
            no: t.get_attribute("dynamic_attributes", "#{type}_no") || "",
            f: t.get_attribute("dynamic_attributes", "#{type}_func"), 
            t: t.get_attribute("dynamic_attributes", "site_type") || "", 
            area: area_val.round(2) 
          }
          
          if type == 'site'
            bldgs = self.find_buildings_on_site(t)
            t_gfa = bldgs.reduce(0) { |sum, b| sum + (b[:area] || 0) }
            t_base = bldgs.reduce(0) { |sum, b| sum + (b[:base_area] || 0) }
            site_area = area_val > 0 ? area_val : 0.001
            item[:gfa] = t_gfa.round(2)
            item[:far] = (t_gfa / site_area).round(2)
            item[:density] = ((t_base / site_area) * 100).round(1)
          end
          
          list_data << item
        end
        has_global_hl = @overlay && !@overlay.sites_data.empty?
        @dialog_stats.execute_script("refreshUI('#{type}', 'multi', [], [], { list: #{list_data.to_json}, totalArea: #{total_area}, global_hl_on: #{has_global_hl} })")
      end
    end

    def self.find_buildings_on_site(site)
      model = Sketchup.active_model
      bldgs = []
      
      all_bldgs = []
      # Search in model root
      model.entities.each do |e|
        next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        all_bldgs << e if e.get_attribute("dynamic_attributes", "bldg_func")
      end
      
      # Search in sibling context (if nested in a BP group)
      if site.parent && site.parent.entities
        site.parent.entities.each do |e|
          next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          next if all_bldgs.include?(e) # Avoid duplicates
          all_bldgs << e if e.get_attribute("dynamic_attributes", "bldg_func")
        end
      end
      
      all_bldgs.each do |bldg|
        b_tr = bldg.respond_to?(:world_transformation) ? bldg.world_transformation : bldg.transformation
        # Correct World Coordinate Calculation
        local_bottom_center = Geom::Point3d.new(bldg.definition.bounds.center.x, bldg.definition.bounds.center.y, bldg.definition.bounds.min.z)
        world_bottom_center = local_bottom_center.transform(b_tr)
        
        
        if self.point_in_site_vertical?(world_bottom_center, site)
          area = bldg.get_attribute("dynamic_attributes", "bldg_area").to_f || 0.0
          base_area = bldg.get_attribute("dynamic_attributes", "base_area").to_f || 0.0
          bldgs << { 
            id: self.get_short_id(bldg), 
            no: bldg.get_attribute("dynamic_attributes", "bldg_no") || "",
            f: bldg.get_attribute("dynamic_attributes", "bldg_func") || "",
            area: area.round(2),
            base_area: base_area.round(2)
          }
        end
      end
      bldgs
    end

    def self.bounds_overlap_2d?(b1, b2)
      return false if b1.min.x > b2.max.x || b2.min.x > b1.max.x
      return false if b1.min.y > b2.max.y || b2.min.y > b1.max.y
      true
    end

    def self.point_in_site_vertical?(global_pt, site)
      tr = site.respond_to?(:world_transformation) ? site.world_transformation : site.transformation
      tr_inv = tr.inverse
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

    def self.do_toggle_height_check(id_str)
      puts "[Civiscope] Toggling height check for ID: #{id_str}"
      model = Sketchup.active_model
      
      # Find site entity
      site = model.find_entity_by_persistent_id(id_str.to_i)
      site ||= model.entities.to_a.find { |e| self.get_short_id(e) == id_str }
      
      unless site
        puts "[Civiscope] Site not found in model entities list"
        return 
      end
      
      # Ensure Overlay
      self.ensure_height_check_overlay(model)
      
      if @overlay.sites_data.key?(id_str)
        @overlay.sites_data.delete(id_str)
      else
        self.add_site_to_height_check(site)
      end
      
      # Force redraw immediately using refresh
      UI.start_timer(0, false) { Sketchup.active_model.active_view.refresh }
      # Update button state in UI
      self.refresh_stats_ui(model.selection)
    end

    def self.do_set_all_height_checks(status_bool)
      model = Sketchup.active_model
      self.ensure_height_check_overlay(model)
      
      # 递归搜寻全模型所有地块 (通过 definitions 查找最全)
      all_sites = []
      model.definitions.each do |d|
        next if d.image?
        d.instances.each do |inst|
          if inst.get_attribute("dynamic_attributes", "site_func")
            all_sites << inst
          end
        end
      end
      
      if status_bool
        # 全部开启 (仅开启尚未开启的)
        all_sites.each { |s| self.add_site_to_height_check(s) }
      else
        # 全部关闭 (直接清空列表)
        @overlay.sites_data.clear
      end
      
      UI.start_timer(0, false) { model.active_view.refresh }
      self.refresh_stats_ui(model.selection)
    end

    def self.ensure_height_check_overlay(model)
      @overlay ||= CiviscopeHeightCheckOverlay.new
      begin
        model.overlays.add(@overlay) unless model.overlays.to_a.include?(@overlay)
      rescue => e; end
    end

    def self.get_full_world_transform(entity)
      # 递归向上寻找最准确的世界坐标变换
      tr = entity.transformation
      parent = entity.parent
      
      # 向上不断寻找实例直到模型根目录
      while parent && parent.is_a?(Sketchup::ComponentDefinition)
        # 如果达到了模型根目录的定义，停止
        break if parent.is_a?(Sketchup::Model)
        
        # 寻找该定义的实例 (优先取第一个，通常 BP 组在模型中是唯一的逻辑实例)
        inst = parent.instances.first
        break unless inst
        
        # 矩阵累乘：父级变换 * 当前变换
        tr = inst.transformation * tr
        parent = inst.parent
      end
      tr
    end

    def self.add_site_to_height_check(site)
      id_str = self.get_short_id(site)
      return if @overlay.sites_data.key?(id_str)
      
      limit_m = site.get_attribute("dynamic_attributes", "height_limit").to_f
      return if limit_m <= 0
      
      # Get face profile
      definition = site.is_a?(Sketchup::Group) ? site.definition : (site.respond_to?(:definition) ? site.definition : nil)
      return unless definition
      
      face = definition.entities.grep(Sketchup::Face).first
      if face
        # We store LOCAL points and calculate world pts in draw for absolute accuracy
        local_pts = face.outer_loop.vertices.map { |v| v.position }
        @overlay.sites_data[id_str] = {
          local_pts: local_pts,
          violated: false
        }
        self.update_overlay_state(id_str)
      end
    end

    def self.update_overlay_state(id_str)
      return unless @overlay && @overlay.sites_data[id_str]
      data = @overlay.sites_data[id_str]
      
      model = Sketchup.active_model
      # Global lookup
      site = model.find_entity_by_persistent_id(id_str.to_i)
      site ||= model.entities.to_a.find { |e| self.get_short_id(e) == id_str }
      return unless site
      
      # Use World Space for comparison
      tr_site = site.respond_to?(:world_transformation) ? site.world_transformation : site.transformation
      limit_m = site.get_attribute("dynamic_attributes", "height_limit").to_f
      limit_inch = limit_m / 0.0254
      
      # Correct Absolute World Min Z using definition bounds (local space)
      site_box = site.definition.bounds
      site_min_z = (tr_site * site_box.min).z
      
      bldgs = self.find_buildings_on_site(site)
      is_violated = false
      
      bldgs.each do |b_data|
        b_ent = model.find_entity_by_persistent_id(b_data[:id].to_i)
        b_ent ||= model.entities.to_a.find { |e| self.get_short_id(e) == b_data[:id] }
        next unless b_ent
        
        tr_b = b_ent.respond_to?(:world_transformation) ? b_ent.world_transformation : b_ent.transformation
        
        # Calculate true world max Z by transforming all local box corners
        local_box = b_ent.definition.bounds
        w_box = Geom::BoundingBox.new
        (0..7).each { |i| w_box.add(tr_b * local_box.corner(i)) }
        b_max_z = w_box.max.z
        
        if b_max_z > site_min_z + (limit_inch - 0.001)
          is_violated = true
          break
        end
      end
      
      data[:violated] = is_violated
    end

    def self.auto_recalculate(entity, skip_ui_refresh = false, skip_operation = false)
      return unless entity.valid?
      
      if entity.get_attribute("dynamic_attributes", "bldg_func")
        bldg_func = entity.get_attribute("dynamic_attributes", "bldg_func")
        self.apply_material(entity, bldg_func)
        self.calc_bldg_data(entity, skip_operation)
        
        # Real-time height check update for Overlays
        if @overlay && @overlay.respond_to?(:sites_data)
          @overlay.sites_data.keys.each do |site_id|
            # Global lookup for site
            site = Sketchup.active_model.find_entity_by_persistent_id(site_id.to_i)
            # Fallback search if needed (but persistent_id is better)
            unless site
              # Search for it (slow but sure if persistent_id fails)
              site = Sketchup.active_model.entities.to_a.find { |e| self.get_short_id(e) == site_id }
            end
            
            if site
              bldgs = self.find_buildings_on_site(site)
              if bldgs.any? { |b| b[:id] == self.get_short_id(entity) }
                self.update_overlay_state(site_id)
                UI.start_timer(0, false) { Sketchup.active_model.active_view.refresh }
              end
            end
          end
        end
      elsif entity.get_attribute("dynamic_attributes", "site_func")
        site_func = entity.get_attribute("dynamic_attributes", "site_func")
        site_type = entity.get_attribute("dynamic_attributes", "site_type") || site_func
        self.apply_material(entity, site_func, site_type)
        self.calc_site_data(entity, skip_operation)
        
        # Real-time height check update for Overlay
        id_str = self.get_short_id(entity)
        if @overlay && @overlay.sites_data.key?(id_str)
          self.update_overlay_state(id_str)
          Sketchup.active_model.active_view.refresh
        end
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
      b_area = th_m > 0 ? (vol_m3 / th_m).round(2) : 0
      t_area = (fc * b_area).round(2)

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
      # Ensure the entity is unique if it's a component or group with multiple instances
      # so that modifying its definition doesn't affect other instances.
      if entity.respond_to?(:make_unique)
        begin
          # SketchUp automatically handles whether it needs to be made unique
          entity.make_unique 
        rescue
          # Some older versions or specific states might throw, ignore safely
        end
      end

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
      
      (1..floor_count).each do |i|
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
      def onTransformationChanged(e)
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
        return if CiviscopeLayout::Core.class_variable_defined?(:@@skip_observer) && CiviscopeLayout::Core.class_variable_get(:@@skip_observer)
        @definition.instances.each { |inst| CiviscopeLayout::Core.schedule_update(inst) }
      end
    end

    class SelectionWatcher < Sketchup::SelectionObserver
      def onSelectionBulkChange(sel); trigger_refresh(sel); end
      def onSelectionCleared(sel); trigger_refresh(sel); end
      def onSelectionAdded(sel, element); trigger_refresh(sel); end
      def onSelectionRemoved(sel, element); trigger_refresh(sel); end
      
      private
      
      def trigger_refresh(sel)
        begin
          # Use a debounce timer to avoid overwhelming the UI during fast selection changes
          @timer_id ||= nil
          UI.stop_timer(@timer_id) if @timer_id
          @timer_id = UI.start_timer(0.1, false) do
            @timer_id = nil
            begin
              CiviscopeLayout::Core.refresh_stats_ui(Sketchup.active_model.selection)
            rescue => inner_e
              puts "[Civiscope Private Error] Async UI Refresh Failed: #{inner_e.message}"
            end
          end
        rescue => e
          puts "[Civiscope Private Error] Selection Observer Event Failed: #{e.message}"
        end
      end
    end

    class ModelWatcher < Sketchup::ModelObserver
      def onActivePathChanged(model)
        begin
          CiviscopeLayout::Core.refresh_stats_ui(model.selection)
        rescue => e
          puts "[Civiscope Private Error] Model Observer onActivePathChanged Failed: #{e.message}"
        end
      end
    end

    def self.schedule_update(entity)
      @update_timer_id ||= {}
      guid = entity.respond_to?(:guid) ? entity.guid : entity.object_id.to_s
      UI.stop_timer(@update_timer_id[guid]) if @update_timer_id[guid]
      @update_timer_id[guid] = UI.start_timer(0.2, false) do
        @update_timer_id.delete(guid)
        self.auto_recalculate(entity) if entity.valid?
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
        pick_svg = File.join(icon_dir, 'picker.svg')
        paint_svg = File.join(icon_dir, 'paint.svg')
        pick_png = File.join(icon_dir, 'picker.png')
        paint_png = File.join(icon_dir, 'paint.png')
        
        # Use SVG if available for better DPI scaling, otherwise fallback to PNG or ID
        if File.exist?(pick_svg)
          @cursor_pick = UI.create_cursor(pick_svg, 4, 26)
        elsif File.exist?(pick_png)
          @cursor_pick = UI.create_cursor(pick_png, 0, 0)
        else
          @cursor_pick = 632
        end

        if File.exist?(paint_svg)
          @cursor_paint = UI.create_cursor(paint_svg, 4, 26)
        elsif File.exist?(paint_png)
          @cursor_paint = UI.create_cursor(paint_png, 0, 0)
        else
          @cursor_paint = 636
        end
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
              view.refresh
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
              view.refresh
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
        view.refresh
      end
    end

    # --- Overlay Class ---
    class CiviscopeHeightCheckOverlay < Sketchup::Overlay
      attr_accessor :sites_data
      
      def initialize
        super('civiscope_height_check', '地块限高检测图层')
        @sites_data = {} # {id => {pts: [], limit_m: 0, violated: bool, site_min_z: 0}}
      end
      
      def draw(view)
        model = Sketchup.active_model
        @sites_data.each do |id_str, data|
          # Re-fetch site and its latest height limit for real-time sync
          site = model.find_entity_by_persistent_id(id_str.to_i)
          site ||= model.entities.to_a.find { |e| CiviscopeLayout::Core.get_short_id(e) == id_str }
          next unless site
          
          limit_m = site.get_attribute("dynamic_attributes", "height_limit").to_f
          next if limit_m <= 0
          
          # 1. Get Absolute World Transformation (Manual Path Aggregation)
          tr_world = CiviscopeLayout::Core.get_full_world_transform(site)
          
          # 2. Calculate World points
          local_pts = data[:local_pts]
          pts = local_pts.map { |p| p.transform(tr_world) }
          
          limit_inch = limit_m / 0.0254
          is_violated = data[:violated]
          
          # Color Setup
          color = is_violated ? Sketchup::Color.new(255, 0, 0, 70) : Sketchup::Color.new(150, 150, 150, 70)
          edge_color = is_violated ? Sketchup::Color.new(255, 0, 0, 150) : Sketchup::Color.new(100, 100, 100, 150)
          
          # Generate 3D Box geometry for rendering
          top_pts = pts.map { |p| p.offset([0, 0, limit_inch]) }
          
          # Draw Side Faces
          pts.each_with_index do |p, i|
            p2 = pts[(i + 1) % pts.length]
            t1 = top_pts[i]
            t2 = top_pts[(i + 1) % top_pts.length]
            
            view.drawing_color = color
            view.draw(GL_QUADS, p, p2, t2, t1)
            
            # Edges
            view.drawing_color = edge_color
            view.line_width = 1
            view.draw(GL_LINE_STRIP, p, p2, t2, t1, p)
          end
          
          # Draw Top Face
          view.drawing_color = color
          view.draw(GL_POLYGON, top_pts)
          
          # Top Edges
          view.drawing_color = edge_color
          view.draw(GL_LINE_LOOP, top_pts)
        end
      end
    end
    # --- End Overlay Class ---
  end
end

