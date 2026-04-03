# 编码：UTF-8
require 'json' unless defined?(JSON)

module CiviscopeLayout
  module Core

    @dialog_settings = nil

    # ==========================================
    # 数据存取逻辑
    # ==========================================
    def self.get_all_funcs(type)
      defs = type == 'bldg' ? DEFAULT_BLDG_FUNCS : DEFAULT_SITE_FUNCS
      return defs + self.get_custom_funcs(type)
    end

    def self.get_custom_funcs(type)
      key = type == 'bldg' ? "custom_bldg_funcs" : "custom_site_funcs"
      raw = Sketchup.read_default(PLUGIN_NAME, key, "")
      return raw.empty? ? [] : raw.split("||")
    end

    def self.save_custom_funcs(type, arr)
      key = type == 'bldg' ? "custom_bldg_funcs" : "custom_site_funcs"
      Sketchup.write_default(PLUGIN_NAME, key, arr.join("||"))
    end

    def self.get_custom_colors
      raw = Sketchup.read_default(PLUGIN_NAME, "custom_colors", "{}")
      begin
        JSON.parse(raw)
      rescue
        {}
      end
    end

    def self.save_custom_colors(hash)
      Sketchup.write_default(PLUGIN_NAME, "custom_colors", hash.to_json)
    end

    def self.get_stats_size
      w = Sketchup.read_default(PLUGIN_NAME, "stats_width", 320).to_i
      h = Sketchup.read_default(PLUGIN_NAME, "stats_height", 550).to_i
      [w, h]
    end

    def self.save_stats_size(w, h)
      Sketchup.write_default(PLUGIN_NAME, "stats_width", w.to_i)
      Sketchup.write_default(PLUGIN_NAME, "stats_height", h.to_i)
    end

    # ==========================================
    # UI 弹窗与交互逻辑
    # ==========================================
    def self.show_settings_dialog
      if @dialog_settings && @dialog_settings.visible?
        @dialog_settings.bring_to_front; return
      end
      
      @dialog_settings = UI::HtmlDialog.new({:dialog_title=>"插件设置", :width=>460, :height=>600, :style=>UI::HtmlDialog::STYLE_DIALOG})
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
        stats_size: self.get_stats_size
      }
      
      @dialog_settings.execute_script("renderLists(#{data.to_json})")
    end

  end
end