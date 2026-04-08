# 编码：UTF-8
module CiviscopeLayout
  module Core
    module Logger
      
      # 日志级别定义
      LEVELS = { debug: 0, info: 1, warn: 2, error: 3 } unless defined?(LEVELS)
      
      # 当前日志级别（默认 info）
      @current_level = :info
      
      # 是否启用日志（默认启用）
      @enabled = true
      
      # ==========================================
      # 设置日志级别
      # ==========================================
      def self.set_level(level)
        level = level.to_sym if level.is_a?(String)
        if LEVELS.key?(level)
          @current_level = level
          log(:info, "日志级别已设置为: #{level.upcase}")
        else
          log(:warn, "无效的日志级别: #{level}")
        end
      end
      
      # ==========================================
      # 启用/禁用日志
      # ==========================================
      def self.enable
        @enabled = true
        puts "[Civiscope Logger] 日志系统已启用"
      end
      
      def self.disable
        @enabled = false
      end
      
      # ==========================================
      # 核心日志方法
      # ==========================================
      def self.log(level, message)
        level = level.to_sym if level.is_a?(String)
        
        # 检查是否启用
        return unless @enabled
        
        # 检查级别过滤
        return unless LEVELS[level] && LEVELS[level] >= LEVELS[@current_level]
        
        # 格式化输出
        timestamp = Time.now.strftime("%H:%M:%S")
        prefix = "[Civiscope #{level.upcase}]"
        
        # 根据级别选择颜色标记（仅用于终端）
        output = "#{prefix} #{timestamp} - #{message}"
        
        # 输出到 Ruby 控制台
        puts output
        
        # 可扩展：写入日志文件
        # self.write_to_file(level, message, timestamp)
      end
      
      # ==========================================
      # 快捷方法
      # ==========================================
      def self.debug(message)
        log(:debug, message)
      end
      
      def self.info(message)
        log(:info, message)
      end
      
      def self.warn(message)
        log(:warn, message)
      end
      
      def self.error(message)
        log(:error, message)
      end
      
      # ==========================================
      # 带上下文的日志方法
      # ==========================================
      def self.log_with_context(level, context, message)
        full_message = "[#{context}] #{message}"
        log(level, full_message)
      end
      
      # ==========================================
      # 获取当前配置（用于调试）
      # ==========================================
      def self.get_config
        {
          level: @current_level,
          enabled: @enabled,
          available_levels: LEVELS.keys
        }
      end
      
      # ==========================================
      # 可扩展：写入日志文件（预留）
      # ==========================================
      # def self.write_to_file(level, message, timestamp)
      #   log_path = File.join(CiviscopeLayout::Core.plugin_dir, 'logs', 'civiscope.log')
      #   # 确保日志目录存在
      #   FileUtils.mkdir_p(File.dirname(log_path)) unless File.exist?(File.dirname(log_path))
      #   File.open(log_path, 'a') { |f| f.puts("#{timestamp} [#{level.upcase}] #{message}") }
      # end
      
    end
  end
end