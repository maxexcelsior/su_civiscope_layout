# 编码：UTF-8
module ArchcityLayout
  module Core

    @dialog_stats = nil
    @selection_observer = nil
    @entity_observers = {}
    @def_entities_observers = {} 
    @timer_id = nil
    @sel_timer_id = nil # 新增：用于选择监听防抖的计时器
    @current_active_tab = 'tab-bldg'
    @is_tab_switch = false

    class << self
      attr_accessor :timer_id
    end

    # ==========================================
    # 1. 基础服务 (图层与材质)
    # ==========================================
    def self.ensure_layer(layer_name)
      model = Sketchup.active_model
      model.layers[layer_name] || model.layers.add(layer_name)
    end

    def self.apply_material(entity, type_or_func_name)
      return unless type_or_func_name && !type_or_func_name.empty?
      mats = Sketchup.active_model.materials
      mat_name = "Archcity_#{type_or_func_name}"
      mat = mats[mat_name]
      unless mat
        mat = mats.add(mat_name)
        color_rgb = COLOR_MAP[type_or_func_name] || [230, 230, 230] 
        mat.color = Sketchup::Color.new(color_rgb[0], color_rgb[1], color_rgb[2])
      end
      # 只有材质发生改变时才重新赋值以避免产生多余的撤销步
      entity.material = mat if entity.material != mat
    end

    # ==========================================
    # 2. UI 路由与智能状态分发
    # ==========================================
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
      
      # 需求1：如果未选择任何元素，显示全局空状态
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
        # 若是用户刚点击了tab切换，则绝对尊重当前选中的tab；否则如果是在视口点击模型，才进行智能推测
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
        @dialog_stats.execute_script("refreshUI('#{type}', 'multi', [], [], { list: #{list_data.to_json}, total: #{total_area.round(2)} })")
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
        
        # 以建筑边界盒底面中心点为检测基准（精确计算异形地块内建筑）
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

    # ==========================================
    # 3. 核心几何数据转换与运算
    # ==========================================
    def self.do_convert_bldg
      model = Sketchup.active_model
      model.start_operation('转换为CIM体块', true)
      target_layer = self.ensure_layer("CIM-building") 

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
      model.start_operation('应用体块参数', true)
      model.selection.to_a.each do |inst|
        next unless inst.get_attribute("dynamic_attributes", "bldg_func")
        inst.set_attribute("dynamic_attributes", "floor_height", h.to_s)
        inst.set_attribute("dynamic_attributes", "bldg_func", f.to_s)
        inst.set_attribute("dynamic_attributes", "bldg_no", no.to_s)
        self.auto_recalculate(inst, true) 
      end
      self.refresh_stats_ui(model.selection)
      model.commit_operation
    end

    def self.do_convert_site
      model = Sketchup.active_model
      model.start_operation('转换为CIM地块', true)
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
        self.auto_recalculate(inst, true)
        new_selection << inst
      end
      
      model.selection.clear
      model.selection.add(new_selection) unless new_selection.empty?
      self.refresh_stats_ui(model.selection)
      model.commit_operation
    end

    def self.do_apply_site(t, f, no)
      model = Sketchup.active_model
      model.start_operation('应用地块参数', true)
      model.selection.to_a.each do |inst|
        next unless inst.get_attribute("dynamic_attributes", "site_func")
        inst.set_attribute("dynamic_attributes", "site_type", t.to_s)
        inst.set_attribute("dynamic_attributes", "site_func", f.to_s)
        inst.set_attribute("dynamic_attributes", "site_no", no.to_s)
        self.auto_recalculate(inst, true) 
      end
      self.refresh_stats_ui(model.selection)
      model.commit_operation
    end

    def self.auto_recalculate(entity, skip_ui_refresh = false)
      return unless entity.valid?
      
      if entity.get_attribute("dynamic_attributes", "bldg_func")
        self.calc_bldg_data(entity)
      elsif entity.get_attribute("dynamic_attributes", "site_func")
        self.calc_site_data(entity)
      end
      
      self.refresh_stats_ui(Sketchup.active_model.selection) unless skip_ui_refresh
    end

    def self.calc_bldg_data(entity)
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

      # 判断数据是否有变化，避免无谓的覆写引起多余撤销步
      need_update = (entity.get_attribute("dynamic_attributes", "bldg_area") != t_area.to_s) ||
                    (entity.get_attribute("dynamic_attributes", "floor_count") != fc.to_s) ||
                    (entity.get_attribute("dynamic_attributes", "base_area") != b_area.to_s) ||
                    (entity.get_attribute("dynamic_attributes", "total_height") != th_m.to_s)

      if need_update
        model = Sketchup.active_model
        # transparent: true (第四个参数) 将修改合并到上一个 SketchUp 操作（比如缩放或移动）中
        model.start_operation('更新体块数据', true, false, true) 
        
        entity.set_attribute("dynamic_attributes", "bldg_area", t_area.to_s)
        entity.set_attribute("dynamic_attributes", "floor_count", fc.to_s)
        entity.set_attribute("dynamic_attributes", "base_area", b_area.to_s)
        entity.set_attribute("dynamic_attributes", "total_height", th_m.to_s)
        
        model.commit_operation
      end

      self.apply_material(entity, bldg_func)
    end

    def self.calc_site_data(entity)
      total_face_area_sq_inch = 0.0
      entity.definition.entities.grep(Sketchup::Face).each do |face|
        total_face_area_sq_inch += face.area
      end
      
      tr = entity.transformation
      scale_factor = tr.xscale * tr.yscale
      site_area_m2 = (total_face_area_sq_inch * scale_factor * (0.0254 ** 2)).round(2)
      
      site_type = entity.get_attribute("dynamic_attributes", "site_type")

      if entity.get_attribute("dynamic_attributes", "site_area") != site_area_m2.to_s
        model = Sketchup.active_model
        model.start_operation('更新地块数据', true, false, true)
        entity.set_attribute("dynamic_attributes", "site_area", site_area_m2.to_s)
        model.commit_operation
      end
      
      self.apply_material(entity, site_type)
    end

    # ==========================================
    # 4. 监听器引擎 (需求3/4: 加入防抖机制)
    # ==========================================
    class MassingEntityObserver < Sketchup::EntityObserver
      def onChangeEntity(e); ArchcityLayout::Core.schedule_update(e); end
    end

    class BimEntitiesObserver < Sketchup::EntitiesObserver
      def initialize(d); @definition = d; end
      def onElementAdded(es, e); trigger_update; end
      def onElementModified(es, e); trigger_update; end
      def onElementRemoved(es, e); trigger_update; end
      def trigger_update
        @definition.instances.each { |inst| ArchcityLayout::Core.schedule_update(inst) }
      end
    end

    class SelectionWatcher < Sketchup::SelectionObserver
      def onSelectionBulkChange(sel)
        # 加入极短的防抖处理，确保多选框选时获取完整的选中项，避免多次空触发
        UI.stop_timer(@sel_timer_id) if @sel_timer_id
        @sel_timer_id = UI.start_timer(0.1, false) do
          ArchcityLayout::Core.refresh_stats_ui(Sketchup.active_model.selection)
        end
      end
      
      def onSelectionCleared(sel)
        ArchcityLayout::Core.refresh_stats_ui(sel)
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

  end
end