# 编码：UTF-8
module ArchcityLayout
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

    # ==========================================
    # UI 弹窗与交互逻辑
    # ==========================================
    def self.show_settings_dialog
      if @dialog_settings && @dialog_settings.visible?
        @dialog_settings.bring_to_front; return
      end
      
      @dialog_settings = UI::HtmlDialog.new({:dialog_title=>"⚙️ 插件设置", :width=>400, :height=>450, :style=>UI::HtmlDialog::STYLE_DIALOG})
      @dialog_settings.set_file(File.join(__dir__, 'ui', 'ui_settings.html'))
      
      @dialog_settings.add_action_callback("ready") { self.refresh_settings_ui }
      
      @dialog_settings.add_action_callback("add_custom_func") do |_, type, val|
        arr = self.get_custom_funcs(type)
        defs = type == 'bldg' ? DEFAULT_BLDG_FUNCS : DEFAULT_SITE_FUNCS
        unless arr.include?(val) || defs.include?(val)
          arr << val
          self.save_custom_funcs(type, arr)
          self.refresh_settings_ui
          self.refresh_stats_ui(Sketchup.active_model.selection) # 通知统计面板同步刷新
        end
      end
      
      @dialog_settings.add_action_callback("del_custom_func") do |_, type, val|
        arr = self.get_custom_funcs(type)
        arr.delete(val)
        self.save_custom_funcs(type, arr)
        self.refresh_settings_ui
        self.refresh_stats_ui(Sketchup.active_model.selection)
      end

      @dialog_settings.set_on_closed { @dialog_settings = nil }
      @dialog_settings.show
    end

    def self.refresh_settings_ui
      return unless @dialog_settings
      @dialog_settings.execute_script("renderLists(#{DEFAULT_BLDG_FUNCS.to_json}, #{self.get_custom_funcs('bldg').to_json}, #{DEFAULT_SITE_FUNCS.to_json}, #{self.get_custom_funcs('site').to_json})")
    end

  end
end