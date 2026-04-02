# 编码：UTF-8
require 'sketchup.rb'
require 'extensions.rb'

module GeminiPlugins
  module MassingArea
    unless file_loaded?(__FILE__)
      # 创建扩展程序实例
      ex = SketchupExtension.new('强排工具箱', 'su_archcity_layout/main')
      
      # 扩展程序信息
      ex.description = '用于统计群组或组件体块的建筑面积。基于闭合实体的体积和指定层高进行计算 (面积 = 体积 / 层高)。'
      ex.version     = '1.0.0'
      ex.copyright   = '© 2026'
      ex.creator     = 'Gemini'
      
      # 注册扩展程序
      Sketchup.register_extension(ex, true)
      
      file_loaded(__FILE__)
    end
  end
end