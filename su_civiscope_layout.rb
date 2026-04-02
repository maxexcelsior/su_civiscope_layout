# 编码：UTF-8
require 'sketchup.rb'
require 'extensions.rb'

module GeminiPlugins
  module MassingArea
    unless file_loaded?(__FILE__)
      # 创建扩展程序实例
      ex = SketchupExtension.new('Civiscope Layout', 'su_civiscope_layout/main')
      
      # 扩展程序信息
      ex.description = '用于强排统计的SU插件'
      ex.version     = '1.0.0'
      ex.copyright   = '© 2026'
      ex.creator     = 'Gemini'
      
      # 注册扩展程序
      Sketchup.register_extension(ex, true)
      
      file_loaded(__FILE__)
    end
  end
end