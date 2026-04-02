# 编码：UTF-8
require 'sketchup.rb'

module ArchcityLayout
  module Core
    
    # ==========================================
    # 0. 全局配置、颜色与数据管理
    # ==========================================
    PLUGIN_NAME = "Archcity_Layout"
    VERSION = "beta 0.0.1"
    AUTHOR = "MaxExcelsior"
    
    # 将“住宅”修正为“居住”以匹配你的颜色需求
    DEFAULT_FUNCS = ["办公", "商业", "居住", "公服设施", "市政设施", "交通设施"]

    # 建筑功能标准色卡 (RGB)
    COLOR_MAP = {
      "办公"     => [221, 5, 166],
      "商业"     => [255, 0, 63],
      "居住"     => [255, 255, 0],
      "公服设施" => [255, 223, 127],
      "市政设施" => [0, 138, 184],
      "交通设施" => [144, 144, 144]
    }

    # 【Bug修复】放弃 JSON，改用特定的分隔符 || 来避免 SketchUp 注册表存储转义错误
    def self.get_all_funcs
      custom_funcs = self.get_custom_funcs
      return DEFAULT_FUNCS + custom_funcs
    end

    def self.get_custom_funcs
      raw_string = Sketchup.read_default(PLUGIN_NAME, "custom_funcs_v2", "")
      return raw_string.empty? ? [] : raw_string.split("||")
    end

    def self.save_custom_funcs(arr)
      Sketchup.write_default(PLUGIN_NAME, "custom_funcs_v2", arr.join("||"))
    end

    @dialog_stats = nil
    @dialog_settings = nil
    @dialog_about = nil
    @selection_observer = nil
    @entity_observers = {}
    @def_entities_observers = {} 
    @timer_id = nil

    # ==========================================
    # 1. 材质自动赋予逻辑
    # ==========================================
    def self.apply_material(entity, func_name)
      return unless func_name && !func_name.empty?
      
      model = Sketchup.active_model
      mats = model.materials
      
      # 创建带有专属前缀的材质名称，防止与场景原材质冲突
      mat_name = "Archcity_#{func_name}"
      mat = mats[mat_name]
      
      # 如果材质面板里还没有这个材质，就新建一个
      unless mat
        mat = mats.add(mat_name)
        # 如果是用户自定义功能，默认给一个柔和的浅灰色
        color_rgb = COLOR_MAP[func_name] || [230, 230, 230] 
        mat.color = Sketchup::Color.new(color_rgb[0], color_rgb[1], color_rgb[2])
      end
      
      # 将材质赋予体块群组/组件外部
      entity.material = mat
    end

    # ==========================================
    # 2. 工具一：统计 (Stats)
    # ==========================================
    def self.show_stats_dialog
      if @dialog_stats && @dialog_stats.visible?
        @dialog_stats.bring_to_front
        return
      end
      
      @dialog_stats = UI::HtmlDialog.new({
        :dialog_title => "📊 统计中心", 
        :width => 320, 
        :height => 550, 
        :style => UI::HtmlDialog::STYLE_DIALOG
      })
      
      html_file = File.join(__dir__, 'ui_stats.html')
      @dialog_stats.set_file(html_file)
      
      @dialog_stats.add_action_callback("convert") { self.do_convert }
      @dialog_stats.add_action_callback("apply_params") do |_, h, f, no| 
        self.do_apply(h, f, no) 
      end
      
      @dialog_stats.add_action_callback("ready") { self.refresh_stats_ui(Sketchup.active_model.selection) }
      @dialog_stats.set_on_closed { @dialog_stats = nil }
      @dialog_stats.show
      
      unless @selection_observer
        @selection_observer = SelectionWatcher.new
        Sketchup.active_model.selection.add_observer(@selection_observer)
      end
    end

    def self.get_short_id(target)
      target.persistent_id != 0 ? target.persistent_id.to_s : target.guid.split('-').first
    end

    def self.refresh_stats_ui(sel)
      return unless @dialog_stats
      all_funcs = self.get_all_funcs
      targets = sel.grep(Sketchup::Group) + sel.grep(Sketchup::ComponentInstance)
      
      if targets.empty?
        @dialog_stats.execute_script("refreshUI('empty', [], {})")
        return
      end

      bim_targets = targets.select { |t| t.respond_to?(:get_attribute) && t.get_attribute("dynamic_attributes", "floor_height") }

      if bim_targets.empty?
        @dialog_stats.execute_script("refreshUI('normal', [], {})")
      elsif bim_targets.length == 1
        t = bim_targets.first
        self.attach_observers(t)
        data = {
          id: self.get_short_id(t),
          no: t.get_attribute("dynamic_attributes", "bldg_no") || "",
          h: t.get_attribute("dynamic_attributes", "floor_height"),
          f: t.get_attribute("dynamic_attributes", "bldg_func"),
          th: t.get_attribute("dynamic_attributes", "total_height"),
          fc: t.get_attribute("dynamic_attributes", "floor_count"),
          ba: t.get_attribute("dynamic_attributes", "base_area"),
          area: t.get_attribute("dynamic_attributes", "bldg_area")
        }
        @dialog_stats.execute_script("refreshUI('bim', #{all_funcs.to_json}, #{data.to_json})")
      else
        list_data = []
        total_area = 0.0
        bim_targets.each do |t|
          self.attach_observers(t)
          area_val = t.get_attribute("dynamic_attributes", "bldg_area").to_f
          total_area += area_val
          list_data << { 
            id: self.get_short_id(t), 
            no: t.get_attribute("dynamic_attributes", "bldg_no") || "",
            f: t.get_attribute("dynamic_attributes", "bldg_func"), 
            area: area_val.round(2) 
          }
        end
        data = { list: list_data, total: total_area.round(2) }
        @dialog_stats.execute_script("refreshUI('multi', [], #{data.to_json})")
      end
    end

    # ==========================================
    # 3. 工具二：全局设置
    # ==========================================
    def self.show_settings_dialog
      if @dialog_settings && @dialog_settings.visible?
        @dialog_settings.bring_to_front
        return
      end
      @dialog_settings = UI::HtmlDialog.new({:dialog_title=>"⚙️ 插件设置", :width=>400, :height=>450, :style=>UI::HtmlDialog::STYLE_DIALOG})
      
      html_file = File.join(__dir__, 'ui_settings.html')
      @dialog_settings.set_file(html_file)
      
      @dialog_settings.add_action_callback("ready") { self.refresh_settings_ui }
      
      @dialog_settings.add_action_callback("add_custom_func") do |_, val|
        arr = self.get_custom_funcs
        unless arr.include?(val) || DEFAULT_FUNCS.include?(val)
          arr << val
          self.save_custom_funcs(arr)
          self.refresh_settings_ui
          self.refresh_stats_ui(Sketchup.active_model.selection)
        end
      end
      
      @dialog_settings.add_action_callback("del_custom_func") do |_, val|
        arr = self.get_custom_funcs
        arr.delete(val)
        self.save_custom_funcs(arr)
        self.refresh_settings_ui
        self.refresh_stats_ui(Sketchup.active_model.selection)
      end

      @dialog_settings.set_on_closed { @dialog_settings = nil }
      @dialog_settings.show
    end

    def self.refresh_settings_ui
      @dialog_settings.execute_script("renderFuncs(#{DEFAULT_FUNCS.to_json}, #{self.get_custom_funcs.to_json})") if @dialog_settings
    end

    # ==========================================
    # 4. 工具三：关于
    # ==========================================
    def self.show_about_dialog
      if @dialog_about && @dialog_about.visible?
        @dialog_about.bring_to_front
        return
      end
      @dialog_about = UI::HtmlDialog.new({:dialog_title=>"ℹ️ 关于", :width=>280, :height=>300, :style=>UI::HtmlDialog::STYLE_DIALOG})
      
      html_file = File.join(__dir__, 'ui_about.html')
      @dialog_about.set_file(html_file)

      @dialog_about.add_action_callback("ready") do |_|
        @dialog_about.execute_script("setInfo('#{VERSION}', '#{AUTHOR}');")
      end

      @dialog_about.set_on_closed { @dialog_about = nil }
      @dialog_about.show
    end

    # ==========================================
    # 5. 底层几何与事件逻辑 
    # ==========================================
    class MassingEntityObserver < Sketchup::EntityObserver
      def onChangeEntity(entity)
        ArchcityLayout::Core.schedule_update(entity)
      end
    end

    class BimEntitiesObserver < Sketchup::EntitiesObserver
      def initialize(definition)
        @definition = definition
      end
      def onElementAdded(entities, entity); trigger_update; end
      def onElementModified(entities, entity); trigger_update; end
      def onElementRemoved(entities, entity); trigger_update; end
      
      def trigger_update
        @definition.instances.each { |inst| ArchcityLayout::Core.schedule_update(inst) }
      end
    end

    class SelectionWatcher < Sketchup::SelectionObserver
      def onSelectionBulkChange(sel); ArchcityLayout::Core.refresh_stats_ui(sel); end
      def onSelectionCleared(sel); ArchcityLayout::Core.refresh_stats_ui(sel); end
    end

    class << self
      attr_accessor :timer_id
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

    def self.do_convert
      model = Sketchup.active_model
      model.start_operation('转换为智能体块', true)
      model.selection.each do |target|
        next unless target.respond_to?(:manifold?) && target.manifold?
        instance = target.is_a?(Sketchup::Group) ? target.to_component : target
        definition = instance.definition
        
        default_func = DEFAULT_FUNCS[0]
        
        definition.set_attribute("dynamic_attributes", "_formatversion", 1.0)
        definition.set_attribute("dynamic_attributes", "floor_height", "3.0")
        instance.set_attribute("dynamic_attributes", "floor_height", "3.0")
        instance.set_attribute("dynamic_attributes", "bldg_func", default_func)
        instance.set_attribute("dynamic_attributes", "bldg_no", "") 
        
        self.attach_observers(instance)
        self.auto_recalculate(instance)
      end
      model.commit_operation
    end

    def self.do_apply(h, f, no)
      model = Sketchup.active_model
      model.start_operation('应用体块参数', true)
      model.selection.each do |inst|
        next unless inst.is_a?(Sketchup::ComponentInstance)
        inst.set_attribute("dynamic_attributes", "floor_height", h.to_s)
        inst.set_attribute("dynamic_attributes", "bldg_func", f.to_s)
        inst.set_attribute("dynamic_attributes", "bldg_no", no.to_s)
        self.auto_recalculate(inst) 
      end
      model.commit_operation
    end

    def self.auto_recalculate(entity)
      return unless entity.valid? && entity.manifold?
      
      h_attr = entity.get_attribute("dynamic_attributes", "floor_height") || entity.definition.get_attribute("dynamic_attributes", "floor_height")
      floor_height_m = h_attr.to_f
      return if floor_height_m <= 0

      bounds = entity.bounds
      min_z_inch = bounds.min.z
      max_z_inch = bounds.max.z
      
      total_height_m = ((max_z_inch - min_z_inch) * 0.0254).round(2)
      floor_count = total_height_m > 0 ? (total_height_m / floor_height_m).floor : 0
      
      vol_m3 = entity.volume * (0.0254 ** 3)
      total_area = (vol_m3 / floor_height_m).round(2)
      base_area = total_height_m > 0 ? (vol_m3 / total_height_m).round(2) : 0

      entity.set_attribute("dynamic_attributes", "bldg_area", total_area.to_s)
      entity.set_attribute("dynamic_attributes", "floor_count", floor_count.to_s)
      entity.set_attribute("dynamic_attributes", "base_area", base_area.to_s)
      entity.set_attribute("dynamic_attributes", "total_height", total_height_m.to_s)

      # ==== 触发材质自动更新 ====
      current_func = entity.get_attribute("dynamic_attributes", "bldg_func")
      self.apply_material(entity, current_func)

      self.refresh_stats_ui(Sketchup.active_model.selection)
    end

    # ==========================================
    # 6. 注册工具栏 (Toolbar)
    # ==========================================
    unless file_loaded?(__FILE__)
      toolbar = UI::Toolbar.new("Archcity Layout")

      cmd1 = UI::Command.new("统计") { self.show_stats_dialog }
      cmd1.tooltip = "体块统计与参数设置"
      icon1_path = File.join(__dir__, 'cal.svg')
      if File.exist?(icon1_path)
        cmd1.small_icon = icon1_path
        cmd1.large_icon = icon1_path
      end
      toolbar = toolbar.add_item(cmd1)

      cmd2 = UI::Command.new("设置") { self.show_settings_dialog }
      cmd2.tooltip = "全局属性与分类设置"
      icon2_path = File.join(__dir__, 'setting.svg')
      if File.exist?(icon2_path)
        cmd2.small_icon = icon2_path
        cmd2.large_icon = icon2_path
      end
      toolbar = toolbar.add_item(cmd2)

      cmd3 = UI::Command.new("关于") { self.show_about_dialog }
      cmd3.tooltip = "关于此插件"
      icon3_path = File.join(__dir__, 'info.svg')
      if File.exist?(icon3_path)
        cmd3.small_icon = icon3_path
        cmd3.large_icon = icon3_path
      end
      toolbar = toolbar.add_item(cmd3)

      toolbar.restore
      file_loaded(__FILE__)
    end
  end
end