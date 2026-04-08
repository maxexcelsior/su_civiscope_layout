# 编码：UTF-8
require 'sketchup.rb'
require 'json' 

module CiviscopeLayout
  module Core
    
    # ==========================================
    # 0. 全局常量与配置中心
    # ==========================================
    PLUGIN_NAME = "Civiscope_Layout" unless defined?(PLUGIN_NAME)
    VERSION = "0.1.3-beta" unless defined?(VERSION)
    AUTHOR = "MaxExcelsior" unless defined?(AUTHOR)
    
    DEFAULT_BLDG_FUNCS = ["办公", "商业", "居住", "公服设施", "市政设施", "交通设施"] unless defined?(DEFAULT_BLDG_FUNCS)
    DEFAULT_SITE_FUNCS = ["居住用地", "商业用地", "中小学用地", "绿地与广场用地", "道路与交通用地", "公园绿地", "防护绿地", "广场用地", "水域"] unless defined?(DEFAULT_SITE_FUNCS)
    SITE_TYPES = ["建设用地", "绿地与广场用地", "水域"] unless defined?(SITE_TYPES)
    
    class << self
      attr_accessor :skip_recalc
      attr_accessor :timer_id
    end

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
    } unless defined?(COLOR_MAP)

    # ==========================================
    # 1. 加载子功能模块 (顺序很重要)
    # ==========================================
    require_relative 'settings'
    
    # 工具类（新增 logger）
    require_relative 'utils/logger'
    require_relative 'utils/attr_helper'
    require_relative 'utils/geom_helper'
    
    # 逻辑类
    require_relative 'logic/bldg_manager'
    require_relative 'logic/site_manager'
    require_relative 'logic/stats_engine'
    
    # 观察者（新增 observer_manager）
    require_relative 'observers/observer_manager'
    require_relative 'observers/model_watcher'
    require_relative 'observers/selection_watcher'
    require_relative 'observers/entity_watcher'
    
    # UI 与渲染
    require_relative 'ui/picker_tool'
    require_relative 'render/height_overlay'
    require_relative 'ui/stats_dialog'

    # ==========================================
    # 辅助功能：热重载 (开发调试用)
    # ==========================================
    def self.reload
      # 1. 清理现有观察者
      model = Sketchup.active_model
      if model && defined?(ObserverManager)
        ObserverManager.cleanup_all_observers(model)
      end
      
      # 2. 加载主文件
      load __FILE__
      load File.join(__dir__, 'settings.rb')
      
      # 3. 加载工具类（新增 logger）
      load File.join(__dir__, 'utils', 'logger.rb')
      load File.join(__dir__, 'utils', 'attr_helper.rb')
      load File.join(__dir__, 'utils', 'geom_helper.rb')
      
      # 4. 加载逻辑类
      load File.join(__dir__, 'logic', 'bldg_manager.rb')
      load File.join(__dir__, 'logic', 'site_manager.rb')
      load File.join(__dir__, 'logic', 'stats_engine.rb')
      
      # 5. 加载观察者（新增 observer_manager）
      load File.join(__dir__, 'observers', 'observer_manager.rb')
      load File.join(__dir__, 'observers', 'model_watcher.rb')
      load File.join(__dir__, 'observers', 'selection_watcher.rb')
      load File.join(__dir__, 'observers', 'entity_watcher.rb')
      
      # 6. 加载 UI 与渲染
      load File.join(__dir__, 'ui', 'picker_tool.rb')
      load File.join(__dir__, 'render', 'height_overlay.rb')
      load File.join(__dir__, 'ui', 'stats_dialog.rb')
      
      # 7. 输出日志
      Logger.info("代码模块化重载完成")
      UI.messagebox("插件及所有模块已重新加载！\n观察者已清理并重新注册。")
      return true
    end

    # ==========================================
    # 2. 对话框居中辅助方法
    # ==========================================
    def self.center_dialog(dialog, width, height)
      # 获取屏幕尺寸（使用 SketchUp 视口作为参考）
      # 大多数情况下屏幕尺寸可以通过系统获取
      begin
        # 尝试获取主显示器尺寸
        if RUBY_PLATFORM =~ /mswin|mingw|cygwin/
          # Windows: 使用 GetSystemMetrics
          require 'fiddle'
          user32 = Fiddle.dlopen('user32')
          get_system_metrics = Fiddle::Function.new(user32['GetSystemMetrics'], [Fiddle::TYPE_INT], Fiddle::TYPE_INT)
          sm_cxscreen = 0
          sm_cyscreen = 1
          screen_width = get_system_metrics.call(sm_cxscreen)
          screen_height = get_system_metrics.call(sm_cyscreen)
        else
          # macOS/Linux: 使用默认值
          screen_width = 2560
          screen_height = 1440
        end
      rescue
        # 回退到常见分辨率
        screen_width = 1920
        screen_height = 1080
      end
      
      left = [(screen_width / 2 - width) / 2, 0].max  # 左半屏幕水平居中
      top = [(screen_height - height) / 2, 0].max   # 垂直居中
      dialog.set_position(left, top)
    end

    # ==========================================
    # 3. 图片弹窗辅助方法
    # ==========================================
    def self.show_image_dialog(title, image_path)
      unless File.exist?(image_path)
        UI.messagebox("未找到图片文件：#{image_path}")
        return
      end

      dialog = UI::HtmlDialog.new({
        dialog_title: title,
        width: 400,
        height: 500,
        resizable: false,
        style: UI::HtmlDialog::STYLE_DIALOG
      })

      html = <<-HTML
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="UTF-8">
          <style>
            body { margin: 0; padding: 20px; background: #f5f5f5; display: flex; justify-content: center; align-items: center; min-height: 100vh; box-sizing: border-box; }
            img { max-width: 100%; max-height: 100%; object-fit: contain; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
          </style>
        </head>
        <body>
          <img src="file:///#{image_path.gsub('\\', '/')}" alt="#{title}">
        </body>
        </html>
      HTML

      dialog.set_html(html)
      self.center_dialog(dialog, 400, 500)
      dialog.show
    end

    # ==========================================
    # 3. 关于面板 (About)
    # ==========================================
    @dialog_about = nil

    def self.show_about_dialog
      if @dialog_about && @dialog_about.visible?
        @dialog_about.bring_to_front; return
      end
      @dialog_about = UI::HtmlDialog.new({:dialog_title=>"ℹ️ 关于", :width=>600, :height=>400, :style=>UI::HtmlDialog::STYLE_DIALOG})
      @dialog_about.set_file(File.join(__dir__, 'ui', 'ui_about.html'))
      @dialog_about.add_action_callback("ready") { |_| @dialog_about.execute_script("setInfo('#{VERSION}', '#{AUTHOR}');") }

      @dialog_about.add_action_callback("contactAuthor") do |_|
        wechat_path = File.join(__dir__, 'assets', '个人微信.png')
        self.show_image_dialog("联系作者", wechat_path)
      end

      @dialog_about.add_action_callback("supportAuthor") do |_|
        qrcode_path = File.join(__dir__, 'assets', '个人收款码.jpg')
        self.show_image_dialog("打赏作者", qrcode_path)
      end

      @dialog_about.set_on_closed { @dialog_about = nil }
      self.center_dialog(@dialog_about, 600, 400)
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