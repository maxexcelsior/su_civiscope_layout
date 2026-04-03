# 编码：UTF-8
require 'sketchup.rb'
require 'json' 

module CiviscopeLayout
  module Core
    
    # ==========================================
    # 0. 全局常量与配置中心
    # ==========================================
    PLUGIN_NAME = "Civiscope_Layout" unless defined?(PLUGIN_NAME)
    VERSION = "beta 0.1.1" unless defined?(VERSION)
    AUTHOR = "MaxExcelsior" unless defined?(AUTHOR)
    
    DEFAULT_BLDG_FUNCS = ["办公", "商业", "居住", "公服设施", "市政设施", "交通设施"] unless defined?(DEFAULT_BLDG_FUNCS)
    DEFAULT_SITE_FUNCS = ["居住用地", "商业用地", "中小学用地", "绿地与广场用地", "道路与交通用地", "公园绿地", "防护绿地", "广场用地", "水域"] unless defined?(DEFAULT_SITE_FUNCS)
    SITE_TYPES = ["建设用地", "绿地与广场用地", "水域"] unless defined?(SITE_TYPES)

    COLOR_MAP = {
      # 建筑颜色
      "办公" => [221, 5, 166], "商业" => [255, 0, 63], "居住" => [255, 255, 0],
      "公服设施" => [255, 223, 127], "市政设施" => [0, 138, 184], "交通设施" => [144, 144, 144],
      # 地块颜色
      "建设用地" => [252, 241, 217],
      "绿地与广场用地" => [164, 228, 160], 
      "公园绿地" => [11, 250, 61], 
      "防护绿地" => [0, 184, 0], 
      "广场用地" => [217, 217, 217], 
      "水域"     => [129, 255, 255]  
    }

    # ==========================================
    # 1. 加载子功能模块(顺序很重要)
    # ==========================================
    require File.join(__dir__, 'settings.rb')
    require File.join(__dir__, 'stats.rb')

    # ==========================================
    # 辅助功能：热重载 (开发调试用)
    # ==========================================
    def self.reload
      load __FILE__
      load File.join(__dir__, 'settings.rb')
      load File.join(__dir__, 'stats.rb')
      puts "=> Civiscope Layout 代码重载完成!"
      UI.messagebox("插件已重新加载！")
      return true
    end

    # ==========================================
    # 2. 关于面板 (About)
    # ==========================================
    @dialog_about = nil

    def self.show_about_dialog
      if @dialog_about && @dialog_about.visible?
        @dialog_about.bring_to_front; return
      end
      @dialog_about = UI::HtmlDialog.new({:dialog_title=>"ℹ️ 关于", :width=>280, :height=>300, :style=>UI::HtmlDialog::STYLE_DIALOG})
      @dialog_about.set_file(File.join(__dir__, 'ui', 'ui_about.html'))
      @dialog_about.add_action_callback("ready") { |_| @dialog_about.execute_script("setInfo('#{VERSION}', '#{AUTHOR}');") }
      @dialog_about.set_on_closed { @dialog_about = nil }
      @dialog_about.show
    end

    # ==========================================
    # 3. 注册工具条(Toolbar)
    # ==========================================
    unless file_loaded?(__FILE__)
      toolbar = UI::Toolbar.new("Civiscope Layout Tools")

      # 工具1：统计
      cmd1 = UI::Command.new("统计中心") { self.show_stats_dialog }
      cmd1.tooltip = "体块统计与参数设置"
      cmd1.small_icon = File.join(__dir__, 'icon', 'cal.svg') if File.exist?(File.join(__dir__, 'icon', 'cal.svg'))
      cmd1.large_icon = File.join(__dir__, 'icon', 'cal.svg') if File.exist?(File.join(__dir__, 'icon', 'cal.svg'))
      toolbar.add_item(cmd1)

      # 工具2：设置
      cmd2 = UI::Command.new("偏好设置") { self.show_settings_dialog }
      cmd2.tooltip = "全局属性与分类设置"
      cmd2.small_icon = File.join(__dir__, 'icon', 'setting.svg') if File.exist?(File.join(__dir__, 'icon', 'setting.svg'))
      cmd2.large_icon = File.join(__dir__, 'icon', 'setting.svg') if File.exist?(File.join(__dir__, 'icon', 'setting.svg'))
      toolbar.add_item(cmd2)

      # 工具3：导出
      cmd_exp = UI::Command.new("导出结果") { UI.messagebox("导出表单功能开发中...") }
      cmd_exp.tooltip = "导出统计数据"
      cmd_exp.small_icon = File.join(__dir__, 'icon', 'table.svg') if File.exist?(File.join(__dir__, 'icon', 'table.svg'))
      cmd_exp.large_icon = File.join(__dir__, 'icon', 'table.svg') if File.exist?(File.join(__dir__, 'icon', 'table.svg'))
      toolbar.add_item(cmd_exp)

      # 工具4：关于
      cmd3 = UI::Command.new("关于") { self.show_about_dialog }
      cmd3.tooltip = "关于此插件"
      cmd3.small_icon = File.join(__dir__, 'icon', 'info.svg') if File.exist?(File.join(__dir__, 'icon', 'info.svg'))
      cmd3.large_icon = File.join(__dir__, 'icon', 'info.svg') if File.exist?(File.join(__dir__, 'icon', 'info.svg'))
      toolbar.add_item(cmd3)

      # 工具5：重载
      cmd4 = UI::Command.new("重载代码") { self.reload }
      cmd4.tooltip = "重新加载插件代码 (开发用)"
      cmd4.small_icon = File.join(__dir__, 'icon', 'reload.svg') if File.exist?(File.join(__dir__, 'icon', 'reload.svg'))
      cmd4.large_icon = File.join(__dir__, 'icon', 'reload.svg') if File.exist?(File.join(__dir__, 'icon', 'reload.svg'))
      toolbar.add_item(cmd4)

      toolbar.restore
      file_loaded(__FILE__)
    end

  end
end