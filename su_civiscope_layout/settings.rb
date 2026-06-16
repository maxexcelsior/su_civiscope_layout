# 编码：UTF-8
require 'json' unless defined?(JSON)

module CiviscopeLayout
  module Core

    @dialog_settings = nil

    # ==========================================
    # 数据存取逻辑 (本地文件模式)
    # ==========================================
    def self.config_path
      File.join(__dir__, 'settings.json')
    end

    def self.load_config
      path = self.config_path
      if File.exist?(path)
        begin
          return JSON.parse(File.read(path))
        rescue => e
          puts "[Civiscope Settings] Error parsing config file: #{e.message}"
        end
      end
      
      # 若文件不存在且旧的 read_default 可选，则尝试迁移
      {}
    end

    def self.save_config(data)
      begin
        File.write(self.config_path, JSON.pretty_generate(data))
      rescue => e
        puts "[Civiscope Settings] Error saving config file: #{e.message}"
      end
    end

    def self.get_all_funcs(type)
      defs = type == 'bldg' ? DEFAULT_BLDG_FUNCS : DEFAULT_SITE_FUNCS
      return defs + self.get_custom_funcs(type)
    end

    def self.get_custom_funcs(type)
      config = self.load_config
      key = type == 'bldg' ? "custom_bldg_funcs" : "custom_site_funcs"
      return config[key] || []
    end

    def self.save_custom_funcs(type, arr)
      config = self.load_config
      key = type == 'bldg' ? "custom_bldg_funcs" : "custom_site_funcs"
      config[key] = arr
      self.save_config(config)
    end

    def self.get_custom_colors
      config = self.load_config
      config["custom_colors"] || {}
    end

    def self.save_custom_colors(hash)
      config = self.load_config
      config["custom_colors"] = hash
      self.save_config(config)
    end

    def self.get_stats_size
      config = self.load_config
      w = config["stats_width"] || 320
      h = config["stats_height"] || 550
      [w.to_i, h.to_i]
    end

    def self.save_stats_size(w, h)
      config = self.load_config
      config["stats_width"] = w.to_i
      config["stats_height"] = h.to_i
      self.save_config(config)
    end

    def self.get_stats_pos
      config = self.load_config
      x = config["stats_pos_x"]
      y = config["stats_pos_y"]
      [x, y]
    end

    def self.save_stats_pos(x, y)
      config = self.load_config
      if x.nil? || y.nil?
        config.delete("stats_pos_x")
        config.delete("stats_pos_y")
      else
        config["stats_pos_x"] = x.to_i
        config["stats_pos_y"] = y.to_i
      end
      self.save_config(config)
    end

    # 属性刷筛选配置
    def self.get_picker_filter(type)
      config = self.load_config
      key = type == 'bldg' ? "picker_bldg_filter" : "picker_site_filter"
      
      # 默认配置：建筑(功能、层高、类型)，地块(性质、大类、限高)
      default = type == 'bldg' ? 
        {"func" => true, "floor_height" => true, "type" => true} :
        {"func" => true, "type" => true, "height_limit" => true}
      
      config[key] || default
    end

    def self.save_picker_filter(type, filter_hash)
      config = self.load_config
      key = type == 'bldg' ? "picker_bldg_filter" : "picker_site_filter"
      config[key] = filter_hash
      self.save_config(config)
    end

    # ==========================================
    # 计容面积折减设置
    # ==========================================
    DEFAULT_PODIUM_REDUCTION = [
      [12, 0.95],
      [24, 0.90],
      [30, 0.85],
      [40, 0.80]
    ].freeze

    DEFAULT_TOWER_REDUCTION = [
      [100, 0.95],
      [150, 0.92],
      [200, 0.89],
      [250, 0.86],
      [300, 0.83],
      [350, 0.79],
      [400, 0.76],
      [450, 0.73],
      [500, 0.70]
    ].freeze

    def self.get_reduction_settings
      config = self.load_config
      {
        "enabled" => config["reduction_enabled"] || false,
        "podium_reduction" => config["podium_reduction"] || DEFAULT_PODIUM_REDUCTION,
        "tower_reduction" => config["tower_reduction"] || DEFAULT_TOWER_REDUCTION
      }
    end

    def self.save_reduction_settings(enabled, podium_arr, tower_arr)
      config = self.load_config
      config["reduction_enabled"] = enabled ? true : false
      config["podium_reduction"] = podium_arr
      config["tower_reduction"] = tower_arr
      self.save_config(config)
    end

    # 根据建筑类型和高度查找折减系数
    def self.compute_reduction_factor(bldg_type, height_m)
      settings = self.get_reduction_settings
      return 1.0 unless settings['enabled']

      intervals = case bldg_type
      when '裙楼' then settings['podium_reduction']
      when '塔楼', '独立' then settings['tower_reduction']
      else return 1.0
      end

      return 1.0 if intervals.nil? || intervals.empty?

      intervals.each do |entry|
        max_h = entry[0].to_f
        coeff = entry[1].to_f
        return coeff if height_m <= max_h
      end

      1.0  # 超出所有区间则不折减
    end

    # 编号设置（地块编号显示参数）
    def self.get_overlay_number_settings
      config = self.load_config
      {
        "use_height_limit" => config["overlay_use_height_limit"] == true,
        "height_offset" => config["overlay_height_offset"] || 0.0,
        "use_fixed_height" => config["overlay_use_fixed_height"] == true,
        "height" => config["overlay_number_height"] || 2.0
      }
    end

    def self.save_overlay_number_settings(data)
      config = self.load_config
      config["overlay_use_height_limit"] = data["use_height_limit"] == true
      config["overlay_height_offset"] = data["height_offset"].to_f
      config["overlay_use_fixed_height"] = data["use_fixed_height"] == true
      config["overlay_number_height"] = data["height"].to_f
      self.save_config(config)
    end

    # 建筑编号显示参数
    def self.get_overlay_bldg_settings
      config = self.load_config
      {
        "offset" => config["bldg_overlay_offset"] || 0.0
      }
    end

    def self.save_overlay_bldg_settings(data)
      config = self.load_config
      config["bldg_overlay_offset"] = data["offset"].to_f
      self.save_config(config)
    end

    # ==========================================
    # UI 弹窗与交互逻辑
    # ==========================================
    def self.show_settings_dialog
      if @dialog_settings && @dialog_settings.visible?
        @dialog_settings.bring_to_front; return
      end
      
      @dialog_settings = UI::HtmlDialog.new({:dialog_title=>"插件设置", :width=>460, :height=>640, :style=>UI::HtmlDialog::STYLE_DIALOG})
      self.center_dialog(@dialog_settings, 460, 640)
      @dialog_settings.set_file(File.join(__dir__, 'ui', 'ui_settings.html'))
      
      @dialog_settings.add_action_callback("ready") { self.refresh_settings_ui }
      
      @dialog_settings.add_action_callback("add_custom_func") do |_, type, val|
        arr = self.get_custom_funcs(type)
        defs = type == 'bldg' ? DEFAULT_BLDG_FUNCS : DEFAULT_SITE_FUNCS
        unless arr.include?(val) || defs.include?(val)
          arr << val
          self.save_custom_funcs(type, arr)
          self.refresh_settings_ui
          self.refresh_stats_ui(Sketchup.active_model.selection) 
        end
      end
      
      @dialog_settings.add_action_callback("del_custom_func") do |_, type, val|
        arr = self.get_custom_funcs(type)
        arr.delete(val)
        self.save_custom_funcs(type, arr)
        
        # 清理颜色残留
        colors = self.get_custom_colors
        if colors.delete(val)
          self.save_custom_colors(colors)
        end
        
        self.refresh_settings_ui
        self.refresh_stats_ui(Sketchup.active_model.selection)
      end

      @dialog_settings.add_action_callback("update_color") do |_, name, hex|
        colors = self.get_custom_colors
        colors[name] = hex
        self.save_custom_colors(colors)
        
        # 自动更新现存材质实体
        mat_name = "Civiscope_#{name}"
        mat = Sketchup.active_model.materials[mat_name]
        if mat
          mat.color = hex
        end
        
        self.refresh_stats_ui(Sketchup.active_model.selection)
      end

      @dialog_settings.add_action_callback("update_stats_size") do |_, w, h|
        self.save_stats_size(w, h)
        # Try to resize if dialog exists
        if @dialog_stats && @dialog_stats.visible?
          @dialog_stats.set_size(w.to_i, h.to_i)
        end
      end

      @dialog_settings.add_action_callback("update_stats_pos") do |_, x, y|
        self.save_stats_pos(x, y)
        if @dialog_stats && @dialog_stats.visible?
          @dialog_stats.set_position(x.to_i, y.to_i) if x && y
        end
      end

      @dialog_settings.add_action_callback("load_overlay_settings") do
        settings = self.get_overlay_number_settings
        @dialog_settings.execute_script("renderOverlaySettings(#{settings.to_json})")
      end

      @dialog_settings.add_action_callback("save_overlay_settings") do |_, json_str|
        data = JSON.parse(json_str)
        self.save_overlay_number_settings(data)
      end

      @dialog_settings.add_action_callback("load_overlay_bldg_settings") do
        settings = self.get_overlay_bldg_settings
        @dialog_settings.execute_script("renderOverlayBldgSettings(#{settings.to_json})")
      end

      @dialog_settings.add_action_callback("save_overlay_bldg_settings") do |_, json_str|
        data = JSON.parse(json_str)
        self.save_overlay_bldg_settings(data)
      end

      @dialog_settings.add_action_callback("load_reduction_settings") do
        rs = self.get_reduction_settings
        @dialog_settings.execute_script("renderReductionSettings(#{rs.to_json})")
      end

      @dialog_settings.add_action_callback("save_reduction_settings") do |_, enabled, podium_json, tower_json|
        podium_arr = JSON.parse(podium_json)
        tower_arr = JSON.parse(tower_json)
        self.save_reduction_settings(enabled, podium_arr, tower_arr)
      end

      @dialog_settings.set_on_closed { @dialog_settings = nil }
      @dialog_settings.show
    end

    def self.refresh_settings_ui
      return unless @dialog_settings

      data = {
        bldg: { defs: DEFAULT_BLDG_FUNCS, cust: self.get_custom_funcs('bldg') },
        site: { defs: DEFAULT_SITE_FUNCS, cust: self.get_custom_funcs('site') },
        types: SITE_TYPES,
        colors: self.get_custom_colors,
        fallback_colors: COLOR_MAP,
        stats_size: self.get_stats_size,
        stats_pos: self.get_stats_pos,
        overlay_height: self.get_overlay_number_settings["height"]
      }

      @dialog_settings.execute_script("renderLists(#{data.to_json})")
    end

    # 属性刷设置对话框
    @dialog_picker_settings = nil
    
    def self.show_picker_settings_dialog(type)
      if @dialog_picker_settings && @dialog_picker_settings.visible?
        @dialog_picker_settings.bring_to_front; return
      end
      
      @dialog_picker_settings = UI::HtmlDialog.new({
        :dialog_title => "⚙️ 属性刷设置",
        :width => 400,
        :height => 350,
        :style => UI::HtmlDialog::STYLE_DIALOG
      })
      self.center_dialog(@dialog_picker_settings, 400, 350)
      @dialog_picker_settings.set_file(File.join(__dir__, 'ui', 'ui_picker_settings.html'))
      
      @dialog_picker_settings.add_action_callback("load_config") do
        data = {
          bldg: self.get_picker_filter('bldg'),
          site: self.get_picker_filter('site')
        }
        @dialog_picker_settings.execute_script("renderConfig(#{data.to_json})")
      end
      
      @dialog_picker_settings.add_action_callback("save_config") do |_, bldg_json, site_json|
        begin
          bldg_filter = JSON.parse(bldg_json)
          site_filter = JSON.parse(site_json)
          self.save_picker_filter('bldg', bldg_filter)
          self.save_picker_filter('site', site_filter)
          UI.messagebox("设置已保存！")
          @dialog_picker_settings.close
        rescue => e
          UI.messagebox("保存失败: #{e.message}")
        end
      end
      
      @dialog_picker_settings.add_action_callback("close_dialog") do
        @dialog_picker_settings.close
      end
      
      @dialog_picker_settings.set_on_closed { @dialog_picker_settings = nil }
      @dialog_picker_settings.show
    end

  end
end